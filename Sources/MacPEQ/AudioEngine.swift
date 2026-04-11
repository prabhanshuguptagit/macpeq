import CoreAudio
import AudioToolbox
import Foundation
import AVFoundation

/// C function for IOProc callback - must be at file scope
@available(macOS 14.2, *)
fileprivate func ioProcCallback(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData = inClientData else { return noErr }
    let engine = Unmanaged<AudioEngine>.fromOpaque(inClientData).takeUnretainedValue()
    return engine.handleIOProc(
        inputData: inInputData,
        outputData: outOutputData
    )
}

/// AudioEngine manages the complete audio pipeline:
/// System Tap → IOProc → RingBuffer → AUHAL Output → Default Device
///
/// CP1: Pure passthrough, no EQ processing
@available(macOS 14.2, *)
final class AudioEngine {
    
    // MARK: - Audio Objects
    
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    
    // MARK: - State
    
    private var ringBuffer: RingBuffer?
    private var isRunning = false
    private var tapFormat = AudioStreamBasicDescription()  // Actual tap format
    private let ringBufferFrames: Int32 = 16384  // ~340ms at 48kHz
    
    // MARK: - Lifecycle
    
    func start() -> Bool {
        Logger.info("Starting AudioEngine (CP1: passthrough)")
        
        // 1. Get default output device
        guard let defaultDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get default output device")
            return false
        }
        Logger.info("Default output device", metadata: ["id": "\(defaultDeviceID)"])
        
        // 2. Create tap description
        guard createTap() else {
            Logger.error("Failed to create audio tap")
            return false
        }
        
        // 3. Create aggregate device with tap
        guard createAggregateDevice() else {
            Logger.error("Failed to create aggregate device")
            cleanupTap()
            return false
        }
        
        // 4. Create ring buffer (using actual tap format)
        ringBuffer = RingBuffer(
            capacityFrames: ringBufferFrames,
            channels: Int(tapFormat.mChannelsPerFrame),
            bytesPerSample: Int(tapFormat.mBytesPerFrame / tapFormat.mChannelsPerFrame)
        )
        Logger.info("Created ring buffer", metadata: [
            "frames": "\(ringBufferFrames)",
            "channels": "\(tapFormat.mChannelsPerFrame)",
            "sampleRate": "\(Int(tapFormat.mSampleRate))"
        ])
        
        // 5. Setup IOProc on aggregate device
        guard setupIOProc() else {
            Logger.error("Failed to setup IOProc")
            cleanupAggregateDevice()
            cleanupTap()
            return false
        }
        
        // 6. Create AUHAL output unit (plays to default device)
        guard createAUHALOutput(defaultDeviceID: defaultDeviceID) else {
            Logger.error("Failed to create AUHAL output")
            cleanupIOProc()
            cleanupAggregateDevice()
            cleanupTap()
            return false
        }
        
        // 7. Start everything
        guard startAudio() else {
            Logger.error("Failed to start audio")
            cleanupAll()
            return false
        }
        
        isRunning = true
        Logger.info("AudioEngine started successfully")
        return true
    }
    
    func stop() {
        guard isRunning else { return }
        Logger.info("Stopping AudioEngine")
        stopAudio()
        cleanupAll()
        isRunning = false
        Logger.info("AudioEngine stopped")
    }
    
    // MARK: - Setup
    
    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )
        
        guard status == noErr else {
            Logger.error("AudioObjectGetPropertyData failed", metadata: ["status": "\(status)"])
            return nil
        }
        return deviceID
    }
    
    /// Translates a PID to an AudioObjectID process object
    private func translatePIDToProcessObject(_ pid: Int32) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &mutablePid,
            &size,
            &processObject
        )
        
        guard status == noErr, processObject != kAudioObjectUnknown else {
            Logger.error("Failed to translate PID", metadata: ["pid": "\(pid)", "status": "\(status)"])
            return nil
        }
        return processObject
    }
    
    @available(macOS 14.2, *)
    private func createTap() -> Bool {
        // Try device-specific tap instead of global tap for better mute behavior
        // Get default output device UID
        guard let defaultDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get default output device for tap")
            return false
        }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var deviceUIDCF: CFString = "" as CFString
        
        let uidStatus = withUnsafeMutablePointer(to: &deviceUIDCF) { ptr in
            AudioObjectGetPropertyData(defaultDeviceID, &address, 0, nil, &size, ptr)
        }
        
        guard uidStatus == noErr else {
            Logger.error("Failed to get device UID", metadata: ["status": "\(uidStatus)"])
            return false
        }
        
        // Exclude MacPEQ's own process from the tap. Without this, MacPEQ's
        // AUHAL output gets re-captured by the tap on the next IOProc cycle,
        // creating a ~100ms delay feedback loop that sounds like a frozen
        // granular synth slowly moving through the audio.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownProcessObject = translatePIDToProcessObject(ownPID)
        let excludedProcesses: [NSNumber] = ownProcessObject.map { [NSNumber(value: $0)] } ?? []

        let tapDesc = CATapDescription(
            __processes: excludedProcesses,
            andDeviceUID: deviceUIDCF as String,
            withStream: 0
        )

        tapDesc.isPrivate = true
        tapDesc.name = "MacPEQ"
        tapDesc.isExclusive = true  // processes list is an exclusion list

        // With MacPEQ excluded, .muted safely silences the original audio on
        // the device so only our processed AUHAL output reaches speakers.
        // Fall back to .unmuted if we couldn't resolve our own process object
        // (otherwise .muted would silence MacPEQ itself along with everything else).
        let canMute = ownProcessObject != nil
        tapDesc.muteBehavior = canMute ? .muted : .unmuted

        Logger.info("Creating device-specific tap", metadata: [
            "deviceUID": deviceUIDCF as String,
            "excludedPID": "\(ownPID)",
            "excludedProcessObject": ownProcessObject.map { "\($0)" } ?? "nil",
            "mute": canMute ? "muted" : "unmuted",
            "private": "\(tapDesc.isPrivate)",
            "exclusive": "\(tapDesc.isExclusive)"
        ])
        
        let status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            Logger.error("AudioHardwareCreateProcessTap failed", metadata: ["status": "\(status)"])
            return false
        }
        
        // Log tap format
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        let fmtStatus = AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &formatSize, &format)
        if fmtStatus == noErr {
            Logger.info("Tap format", metadata: [
                "rate": "\(Int(format.mSampleRate))",
                "channels": "\(format.mChannelsPerFrame)",
                "format": format.mFormatID == kAudioFormatLinearPCM ? "PCM" : "other",
                "float": "\(format.mFormatFlags & kAudioFormatFlagIsFloat != 0)",
                "interleaved": "\(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)"
            ])
        }
        
        // Store the tap format for later use
        self.tapFormat = format
        
        Logger.info("Tap created", metadata: ["id": "\(tapID)"])
        return true
    }
    
    private func createAggregateDevice() -> Bool {
        // Get tap UID string
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var tapUIDCF: CFString = "" as CFString
        
        let uidStatus = withUnsafeMutablePointer(to: &tapUIDCF) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        
        guard uidStatus == noErr else {
            Logger.error("Failed to get tap UID", metadata: ["status": "\(uidStatus)"])
            return false
        }
        
        // CRITICAL: Use the proper tap list format as per sudara's gist and PRD
        // The tap list is an array of dictionaries with drift compensation
        // kAudioSubTapDriftCompensationKey: true handles clock drift at HAL level
        let uid = UUID().uuidString
        let tapUIDString = tapUIDCF as String
        
        let tapList: [[String: Any]] = [
            [
                kAudioSubTapUIDKey: tapUIDString,
                kAudioSubTapDriftCompensationKey: true
            ]
        ]
        
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacPEQ",
            kAudioAggregateDeviceUIDKey: "com.macpeq.aggregate.\(uid)",
            kAudioAggregateDeviceTapListKey: tapList,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        
        Logger.info("Creating aggregate device with drift compensation", metadata: [
            "uid": uid,
            "tapUID": tapUIDString,
            "driftCompensation": "true"
        ])
        
        let status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        
        // Handle stale aggregate device (error 1852797029)
        if status == 1852797029 {
            Logger.warning("Aggregate device already exists, attempting cleanup and retry")
            
            // Try to find and destroy the stale device
            var lookupAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var staleDeviceID: AudioDeviceID = 0
            var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            var testUID = "com.macpeq.aggregate.\(uid)" as CFString
            
            let lookupStatus = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &lookupAddr,
                UInt32(MemoryLayout<CFString>.size),
                &testUID,
                &deviceSize,
                &staleDeviceID
            )
            
            if lookupStatus == noErr && staleDeviceID != 0 {
                AudioHardwareDestroyAggregateDevice(staleDeviceID)
                Logger.info("Destroyed stale aggregate device", metadata: ["id": "\(staleDeviceID)"])
            }
            
            // Retry with a new unique UID
            let newUID = UUID().uuidString
            let retryDict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacPEQ",
                kAudioAggregateDeviceUIDKey: "com.macpeq.aggregate.\(newUID)",
                kAudioAggregateDeviceTapListKey: tapList,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceIsPrivateKey: true
            ]
            
            let retryStatus = AudioHardwareCreateAggregateDevice(retryDict as CFDictionary, &aggregateDeviceID)
            guard retryStatus == noErr else {
                Logger.error("AudioHardwareCreateAggregateDevice retry failed", metadata: ["status": "\(retryStatus)"])
                return false
            }
        } else if status != noErr {
            Logger.error("AudioHardwareCreateAggregateDevice failed", metadata: ["status": "\(status)"])
            return false
        }
        
        Logger.info("Aggregate device created", metadata: ["id": "\(aggregateDeviceID)"])
        return true
    }
    
    private var ioProcID: AudioDeviceIOProcID?
    private var ioProcCallbackCount = 0
    
    private func setupIOProc() -> Bool {
        Logger.info("Setting up IOProc with C callback")
        
        // Create IOProc using C function pointer
        let status = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            ioProcCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &ioProcID
        )
        
        guard status == noErr else {
            Logger.error("AudioDeviceCreateIOProcID failed", metadata: ["status": "\(status)"])
            return false
        }
        
        Logger.info("IOProc created successfully")
        return true
    }
    
    private func startReadingFromAggregate() {
        Logger.info("Starting aggregate device IOProc")
        guard let ioProcID = ioProcID else {
            Logger.error("No IOProcID to start")
            return
        }
        let status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        Logger.info("AudioDeviceStart result", metadata: ["status": "\(status)"])
    }
    
    private func stopReadingFromAggregate() {
        Logger.info("Stopping aggregate device IOProc")
        guard let ioProcID = ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, ioProcID)
    }
    
    private func cleanupIOProc() {
        if let ioProcID = ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
    }
    
    private var firstIOProc = true
    
    func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let bufferList = inputData.pointee
        guard bufferList.mNumberBuffers > 0 else { return noErr }
        
        let buffer = bufferList.mBuffers
        guard buffer.mData != nil, buffer.mDataByteSize > 0 else { return noErr }
        
        // Log format details once
        if firstIOProc {
            firstIOProc = false
            Logger.info("IOProc format details", metadata: [
                "mNumberBuffers": "\(bufferList.mNumberBuffers)",
                "mNumberChannels": "\(buffer.mNumberChannels)",
                "mDataByteSize": "\(buffer.mDataByteSize)",
                "expectedFrames": "\(Int(buffer.mDataByteSize) / (2 * MemoryLayout<Float>.size))"
            ])
        }
        
        let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
        
        // Calculate peak level for monitoring
        let frameCount = Int(buffer.mDataByteSize) / Int(tapFormat.mBytesPerFrame)
        let sampleCount = frameCount * Int(tapFormat.mChannelsPerFrame)
        
        var peak: Float = 0
        for i in 0..<min(sampleCount, 1024) {
            peak = max(peak, abs(samples[i]))
        }
        
        // Write to ring buffer
        let written = ringBuffer?.write(samples, frameCount: frameCount) ?? 0
        ioProcCallbackCount += 1
        
        // Log first 10 callbacks and silence detection
        let isSilent = peak < 0.001
        if ioProcCallbackCount <= 10 || (ioProcCallbackCount == 10 && isSilent) {
            var meta: [String: String] = [
                "count": "\(ioProcCallbackCount)",
                "peak": String(format: "%.4f", peak),
                "ringFill": String(format: "%.2f", ringBuffer?.fillRatio() ?? 0)
            ]
            if ioProcCallbackCount == 10 && isSilent {
                meta["WARNING"] = "TAP_SILENT - Check System Audio Recording permission"
            }
            Logger.debug("IOProc", metadata: meta)
        }
        
        return noErr
    }

    
    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        Logger.info("Creating AUHAL output unit")
        
        // Create AUHAL output unit
        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        guard let comp = AudioComponentFindNext(nil, &compDesc) else {
            Logger.error("AudioComponentFindNext failed")
            return false
        }
        
        var au: AudioUnit?
        let status = AudioComponentInstanceNew(comp, &au)
        guard status == noErr, let au = au else {
            Logger.error("AudioComponentInstanceNew failed", metadata: ["status": "\(status)"])
            return false
        }
        
        outputAU = au
        
        // Set device
        var deviceID = defaultDeviceID
        let devStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard devStatus == noErr else {
            Logger.error("AudioUnitSetProperty(CurrentDevice) failed", metadata: ["status": "\(devStatus)"])
            return false
        }
        
        // Get output device sample rate to compare with tap
        var outputRateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        let rateStatus = AudioObjectGetPropertyData(deviceID, &outputRateAddr, 0, nil, &rateSize, &outputRate)
        if rateStatus == noErr {
            Logger.info("Output device sample rate", metadata: [
                "outputRate": "\(Int(outputRate))",
                "tapRate": "\(Int(tapFormat.mSampleRate))",
                "match": "\(Int(outputRate) == Int(tapFormat.mSampleRate))"
            ])
        }
        
        // Enable output, disable input
        var enable: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        enable = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        
        // CRITICAL: Configure stream format to match the tap format exactly
        // Use the format read from the tap - Float32, interleaved/non-interleaved as reported
        var format = tapFormat
        
        // Set the input format (what we provide to the AUHAL render callback)
        let fmtStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        Logger.info("Set AUHAL input format", metadata: [
            "status": "\(fmtStatus)",
            "rate": "\(Int(format.mSampleRate))",
            "ch": "\(format.mChannelsPerFrame)",
            "interleaved": "\((format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)",
            "formatID": "\(format.mFormatID)"
        ])
        
        // Set render callback - use inRefCon to pass self, no closures allowed
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
                guard let ioData = ioData else { return noErr }
                let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                return engine.handleAUHALRender(frames: inNumberFrames, buffers: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        let cbStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard cbStatus == noErr else {
            Logger.error("AudioUnitSetProperty(SetRenderCallback) failed", metadata: ["status": "\(cbStatus)"])
            return false
        }
        
        // Initialize
        let initStatus = AudioUnitInitialize(au)
        guard initStatus == noErr else {
            Logger.error("AudioUnitInitialize failed", metadata: ["status": "\(initStatus)"])
            return false
        }
        
        Logger.info("AUHAL output unit created and initialized")
        return true
    }
    
    private var renderCallbackCount: Int = 0
    
    private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = buffers.pointee
        let requestedFrames = Int(frames)
        
        for i in 0..<Int(bufferList.mNumberBuffers) {
            let buffer = bufferList.mBuffers
            guard buffer.mData != nil else { continue }
            
            let channelCount = Int(buffer.mNumberChannels)
            let dest = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            let readFrames = ringBuffer?.read(into: dest, frameCount: requestedFrames) ?? 0
            
            if readFrames < requestedFrames {
                // Zero remaining samples (underflow)
                let samplesToZero = (requestedFrames - readFrames) * channelCount
                let startIdx = readFrames * channelCount
                for j in 0..<samplesToZero {
                    dest[startIdx + j] = 0
                }
            }
        }
        
        renderCallbackCount += 1
        return noErr
    }
    
    // MARK: - Start/Stop
    
    private func startAudio() -> Bool {
        // Start reading from aggregate device in a separate thread
        startReadingFromAggregate()
        Logger.info("Started reading from aggregate device")
        
        // Wait briefly for ring buffer to fill
        Thread.sleep(forTimeInterval: 0.1)
        
        // Start AUHAL
        guard let au = outputAU else { return false }
        let status = AudioOutputUnitStart(au)
        guard status == noErr else {
            Logger.error("AudioOutputUnitStart failed", metadata: ["status": "\(status)"])
            stopReadingFromAggregate()
            return false
        }
        Logger.info("AUHAL output started")
        
        return true
    }
    
    private func stopAudio() {
        if let au = outputAU {
            AudioOutputUnitStop(au)
        }
        stopReadingFromAggregate()
    }
    
    // MARK: - Cleanup
    
    private func cleanupAll() {
        stopReadingFromAggregate()
        cleanupIOProc()
        cleanupAUHAL()
        cleanupAggregateDevice()
        cleanupTap()
        ringBuffer = nil
    }
    
    private func cleanupAUHAL() {
        if let au = outputAU {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputAU = nil
        }
    }
    
    private func cleanupAggregateDevice() {
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }
    
    private func cleanupTap() {
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }
}
