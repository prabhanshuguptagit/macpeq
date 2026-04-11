import CoreAudio
import AudioToolbox
import Foundation

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
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    private var ringBuffer: RingBuffer?
    private var isRunning = false
    private var tapFormat = AudioStreamBasicDescription()
    private let ringBufferFrames: Int32 = 16384
    
    private func getProperty<T>(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        value: inout T
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    }
    
    private func getProperty<T, Q>(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        qualifier: inout Q,
        value: inout T
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(
            objectID, &address,
            UInt32(MemoryLayout<Q>.size), &qualifier,
            &size, &value
        )
    }
    
    func start() -> Bool {
        Logger.info("Starting AudioEngine (CP1: passthrough)")
        
        // 1. Get default output device
        guard let defaultDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get default output device")
            return false
        }
        Logger.info("Default output device", metadata: ["id": "\(defaultDeviceID)"])
        
        // 2. Create tap description
        guard createTap(for: defaultDeviceID) else {
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
        let status = getProperty(of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, value: &deviceID)
        guard status == noErr else {
            Logger.error("AudioObjectGetPropertyData failed", metadata: ["status": "\(status)"])
            return nil
        }
        return deviceID
    }
    
    private func translatePIDToProcessObject(_ pid: Int32) -> AudioObjectID? {
        var processObject: AudioObjectID = 0
        var mutablePid = pid
        let status = getProperty(of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: &mutablePid, value: &processObject)
        guard status == noErr, processObject != kAudioObjectUnknown else {
            Logger.error("Failed to translate PID", metadata: ["pid": "\(pid)", "status": "\(status)"])
            return nil
        }
        return processObject
    }
    
    @available(macOS 14.2, *)
    private func createTap(for deviceID: AudioDeviceID) -> Bool {
        var deviceUIDCF: CFString = "" as CFString
        let uidStatus = withUnsafeMutablePointer(to: &deviceUIDCF) { ptr in
            getProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
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
        
        var format = AudioStreamBasicDescription()
        let fmtStatus = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &format)
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
        var tapUIDCF: CFString = "" as CFString
        let uidStatus = withUnsafeMutablePointer(to: &tapUIDCF) { ptr in
            getProperty(of: tapID, selector: kAudioTapPropertyUID, value: &ptr.pointee)
        }
        guard uidStatus == noErr else {
            Logger.error("Failed to get tap UID", metadata: ["status": "\(uidStatus)"])
            return false
        }
        
        // kAudioSubTapDriftCompensationKey handles clock drift at HAL level
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
        
        let status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            Logger.error("AudioHardwareCreateAggregateDevice failed", metadata: ["status": "\(status)"])
            return false
        }
        
        Logger.info("Aggregate device created", metadata: ["id": "\(aggregateDeviceID)"])
        return true
    }
    
    private var ioProcID: AudioDeviceIOProcID?
    
    private func setupIOProc() -> Bool {
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
        return true
    }
    
    private func startReadingFromAggregate() {
        guard let ioProcID = ioProcID else { return }
        let status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        if status != noErr {
            Logger.error("AudioDeviceStart failed", metadata: ["status": "\(status)"])
        }
    }
    
    private func stopReadingFromAggregate() {
        guard let ioProcID = ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, ioProcID)
    }
    
    private func cleanupIOProc() {
        if let ioProcID = ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
    }
    
    func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        )
        guard bufferList.count > 0 else { return noErr }
        
        // For non-interleaved: one buffer per channel. For interleaved: one buffer with all channels.
        // Write each buffer's data to ring buffer.
        for buffer in bufferList {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { continue }
            
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            let frameCount = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
            ringBuffer?.write(samples, frameCount: frameCount)
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
        
        var outputRate: Float64 = 0
        let rateStatus = getProperty(of: deviceID, selector: kAudioDevicePropertyNominalSampleRate, value: &outputRate)
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
    
    private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
        let requestedFrames = Int(frames)
        
        for buffer in bufferList {
            guard buffer.mData != nil else { continue }
            
            let channelCount = Int(buffer.mNumberChannels)
            let dest = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            let readFrames = ringBuffer?.read(into: dest, frameCount: requestedFrames) ?? 0
            
            if readFrames < requestedFrames {
                let zeroSamples = (requestedFrames - readFrames) * channelCount
                memset(dest.advanced(by: readFrames * channelCount), 0, zeroSamples * MemoryLayout<Float>.size)
            }
        }
        
        return noErr
    }
    
    private func startAudio() -> Bool {
        startReadingFromAggregate()
        guard let au = outputAU else { return false }
        let status = AudioOutputUnitStart(au)
        guard status == noErr else {
            Logger.error("AudioOutputUnitStart failed", metadata: ["status": "\(status)"])
            stopReadingFromAggregate()
            return false
        }
        return true
    }
    
    private func stopAudio() {
        if let au = outputAU {
            AudioOutputUnitStop(au)
        }
        stopReadingFromAggregate()
    }
    
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
