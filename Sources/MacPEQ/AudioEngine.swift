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
    private let sampleRate: Double = 48000  // Will read from tap format
    private let channels: UInt32 = 2
    private let ringBufferFrames: Int = 16384  // ~340ms at 48kHz
    
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
        
        // 4. Create ring buffer
        ringBuffer = RingBuffer(capacityFrames: ringBufferFrames, channels: Int(channels))
        Logger.info("Created ring buffer", metadata: ["frames": "\(ringBufferFrames)"])
        
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
        // Create global stereo tap using sudara's approach
        // Empty array = tap all processes (exclusive=true means array is exclusion list)
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        
        // The convenience init already sets:
        // - exclusive = true (processes array is exclusion list)
        // - mixdown to stereo
        // But we need to set mute and private
        
        // Note: CATapDescription properties are read-only after creation,
        // so we set them via the property setters which work differently
        // Actually, looking at Apple sample - these ARE properties:
        // var description = CATapDescription(); description.name = "..."
        
        // The stereoGlobalTapButExcludeProcesses creates a preconfigured tap,
        // but we can modify it. Let's use properties:
        tapDesc.isPrivate = true
        tapDesc.name = "MacPEQ"
        // For mute behavior, we need to set it via property
        // description.muteBehavior is a CATapMuteBehavior enum
        // .muted silences the tap itself on macOS 15
        // .mutedWhenTapped mutes original when tap is active - may silence Firefox
        // .unmuted = both play (for testing passthrough)
        tapDesc.muteBehavior = .unmuted
        
        Logger.info("Creating global stereo tap", metadata: [
            "mute": "unmuted",
            "private": "\(tapDesc.isPrivate)",
            "exclusive": "\(tapDesc.isExclusive)",
            "processes": "all (empty exclusion list)"
        ])
        
        let status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            Logger.error("AudioHardwareCreateProcessTap failed", metadata: ["status": "\(status)"])
            return false
        }
        
        // Log tap format
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        let fmtStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        if fmtStatus == noErr {
            Logger.info("Tap format", metadata: [
                "rate": "\(Int(format.mSampleRate))",
                "channels": "\(format.mChannelsPerFrame)",
                "format": format.mFormatID == kAudioFormatLinearPCM ? "PCM" : "other",
                "float": "\(format.mFormatFlags & kAudioFormatFlagIsFloat != 0)",
                "interleaved": "\(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)"
            ])
        }
        
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
        
        let tapUIDString = tapUIDCF as String
        
        // Create empty aggregate device first (audiotee approach)
        let uid = UUID().uuidString
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacPEQ",
            kAudioAggregateDeviceUIDKey: "com.macpeq.aggregate.\(uid)",
            kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
            kAudioAggregateDeviceMasterSubDeviceKey: 0,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false
        ]
        
        Logger.info("Creating aggregate device", metadata: ["uid": uid])
        
        let status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        
        guard status == noErr else {
            Logger.error("AudioHardwareCreateAggregateDevice failed", metadata: ["status": "\(status)"])
            return false
        }
        
        Logger.info("Aggregate device created", metadata: ["id": "\(aggregateDeviceID)"])
        
        // Now add the tap to the aggregate device via property (audiotee approach)
        // Target the aggregate device (not the tap!) for kAudioAggregateDevicePropertyTapList
        var tapListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // The tap list is just an array of CFString UIDs (not dictionaries!)
        var tapList: CFArray = [tapUIDCF] as CFArray
        
        let setStatus = AudioObjectSetPropertyData(
            aggregateDeviceID,
            &tapListAddr,
            0, nil,
            UInt32(MemoryLayout<CFArray>.size),
            &tapList
        )
        
        if setStatus != noErr {
            Logger.error("Failed to add tap to aggregate", metadata: ["status": "\(setStatus)"])
            // Don't fail - maybe the tap was already included
        } else {
            Logger.info("Tap added to aggregate device")
        }
        
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
    
    // Test mode: generate sine wave instead of using tap data
    private var testModeSineWave = false
    private var sinePhase: Float = 0
    private let sineFreq: Float = 1000.0
    
    func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let bufferList = inputData.pointee
        guard bufferList.mNumberBuffers > 0 else { return noErr }
        
        let buffer = bufferList.mBuffers
        guard buffer.mData != nil, buffer.mDataByteSize > 0 else { return noErr }
        
        let bytesPerSample = MemoryLayout<Float>.size
        let sampleCount = Int(buffer.mDataByteSize) / bytesPerSample
        
        if testModeSineWave {
            // Generate sine wave directly (bypass tap for testing)
            var localSamples = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount/2 {
                let sample = sin(sinePhase) * 0.3 // 30% volume
                sinePhase += 2 * Float.pi * sineFreq / 48000.0
                if sinePhase > 2 * Float.pi { sinePhase -= 2 * Float.pi }
                localSamples[i*2] = sample     // left
                localSamples[i*2+1] = sample   // right
            }
            localSamples.withUnsafeBufferPointer { ptr in
                ringBuffer?.write(ptr.baseAddress!, count: sampleCount)
            }
            
            ioProcCallbackCount += 1
            if ioProcCallbackCount <= 5 {
                Logger.debug("IOProc TEST MODE (sine)", metadata: [
                    "count": "\(ioProcCallbackCount)",
                    "samples": "\(sampleCount)",
                    "ringFill": String(format: "%.2f", ringBuffer?.fillRatio() ?? 0)
                ])
            }
        } else {
            // Normal tap data passthrough
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            // Calculate peak level for monitoring
            var peak: Float = 0
            var dcOffset: Float = 0
            for i in 0..<min(sampleCount, 1024) {
                peak = max(peak, abs(samples[i]))
                dcOffset += samples[i]
            }
            dcOffset /= Float(min(sampleCount, 1024))
            
            // Write to ring buffer
            let written = ringBuffer?.write(samples, count: sampleCount) ?? 0
            
            // Increment callback count
            ioProcCallbackCount += 1
            
            // Detect silence - warn if first 10 callbacks are all silent
            let isSilent = peak < 0.001
            
            // Log first 10 and occasionally, or if write failed, or if silence detected
            if ioProcCallbackCount <= 10 || ioProcCallbackCount % 500 == 0 || written != sampleCount || (ioProcCallbackCount == 10 && isSilent) {
                // Debug: print first 4 samples
                let s0 = samples[0]
                let s1 = samples[1]
                let s2 = samples[2]
                let s3 = samples[3]
                var meta: [String: String] = [
                    "count": "\(ioProcCallbackCount)",
                    "samples": "\(sampleCount)",
                    "written": "\(written)",
                    "peak": String(format: "%.4f", peak),
                    "s0-1": String(format: "%.4f,%.4f", s0, s1),
                    "ringFill": String(format: "%.2f", ringBuffer?.fillRatio() ?? 0)
                ]
                if ioProcCallbackCount == 10 && isSilent {
                    meta["WARNING"] = "TAP_SILENT"
                }
                Logger.debug("IOProc callback", metadata: meta)
            }
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
        
        // Enable output, disable input
        var enable: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        enable = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        
        // CRITICAL: Configure stream format to match the tap format
        // The tap delivers: 48kHz, Float32, interleaved stereo
        var format = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,  // 2 channels * 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,   // 2 channels * 4 bytes
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // Set the input format (what we provide to the AUHAL render callback)
        let fmtStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        Logger.info("Set AUHAL input format", metadata: ["status": "\(fmtStatus)", "rate": "48000", "ch": "2"])
        
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
    private var lastRenderPeak: Float = -1
    
    private var lastWrittenSample: Float = 0
    
    private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = buffers.pointee
        
        var totalPeak: Float = 0
        var totalReadCount = 0
        var totalSampleCount = 0
        
        for i in 0..<Int(bufferList.mNumberBuffers) {
            let buffer = bufferList.mBuffers
            guard buffer.mData != nil else { continue }
            
            let sampleCount = Int(frames) * Int(buffer.mNumberChannels)
            let dest = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            // Read from ring buffer, zero if underflow
            let readCount = ringBuffer?.read(into: dest, count: sampleCount) ?? 0
            totalReadCount += readCount
            totalSampleCount += sampleCount
            
            // Calculate peak for logging and check for corruption
            var localPeak: Float = 0
            var firstSample: Float = 0
            for j in 0..<readCount {
                let sample = dest[j]
                if j == 0 { firstSample = sample }
                localPeak = max(localPeak, abs(sample))
                totalPeak = max(totalPeak, abs(sample))
            }
            
            // Check for corruption - if first sample differs wildly from last written
            if readCount > 0 {
                let diff = abs(firstSample - lastWrittenSample)
                if diff > 1.0 {
                    Logger.debug("Possible ring buffer discontinuity", metadata: [
                        "firstSample": String(format: "%.4f", firstSample),
                        "lastWritten": String(format: "%.4f", lastWrittenSample),
                        "diff": String(format: "%.4f", diff)
                    ])
                }
                lastWrittenSample = dest[readCount - 1]
            }
            
            if readCount < sampleCount {
                // Zero remaining samples (underflow)
                for j in readCount..<sampleCount {
                    dest[j] = 0
                }
            }
        }
        
        // Log first 10 and occasionally
        renderCallbackCount += 1
        let fillRatio = ringBuffer?.fillRatio() ?? 0
        let underflow = totalReadCount < totalSampleCount
        
        // Detect frozen audio - check if peak is identical to previous
        let isFrozen = abs(totalPeak - lastRenderPeak) < 0.0001 && totalPeak > 0.01
        lastRenderPeak = totalPeak
        
        if renderCallbackCount <= 10 || renderCallbackCount % 100 == 0 || underflow || totalPeak > 1.0 || isFrozen {
            var meta: [String: String] = [
                "callback": "\(renderCallbackCount)",
                "frames": "\(frames)",
                "read": "\(totalReadCount)/\(totalSampleCount)",
                "peak": String(format: "%.4f", totalPeak),
                "ringFill": String(format: "%.2f", fillRatio),
                "underflow": "\(underflow)",
                "haveData": "\(totalReadCount > 0)"
            ]
            if isFrozen {
                meta["FROZEN"] = "YES"
            }
            Logger.debug("AUHAL render", metadata: meta)
        }
        
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
