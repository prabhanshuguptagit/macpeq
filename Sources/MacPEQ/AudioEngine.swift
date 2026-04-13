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

/// AudioEngine lifecycle state machine
@available(macOS 14.2, *)
private enum AudioEngineState {
    case idle           // No tap, no audio
    case building       // Creating tap, aggregate, AUHAL
    case running        // Audio flowing
    case tearingDown    // Stopping AUHAL, destroying aggregate, destroying tap
    case disabled       // Error state, allows retry
    
    var isActive: Bool {
        switch self {
        case .building, .running: return true
        case .idle, .tearingDown, .disabled: return false
        }
    }
}

/// AudioEngine manages the complete audio pipeline:
/// System Tap → IOProc → RingBuffer → EQ Processing → AUHAL Output → Default Device
///
/// CP3: Device switching - survives output device changes
@available(macOS 14.2, *)
final class AudioEngine {
    // Shared instance for device change callbacks. AudioEngine is effectively a singleton -
    // creating a second instance would cause the first to lose device change notifications.
    static weak var shared: AudioEngine?
    
    init() {
        assert(AudioEngine.shared == nil, "AudioEngine is a singleton - only one instance allowed")
    }
    
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    private var ringBuffer: RingBuffer?
    private var isRunning = false
    private var tapFormat = AudioStreamBasicDescription()
    private let ringBufferFrames: Int32 = 32768
    
    // CP2: Single biquad filter per channel
    private var leftFilter: BiquadFilter?
    private var rightFilter: BiquadFilter?
    private var filterEnabled: Bool = true
    
    // CP3: State machine and device change handling
    private var state: AudioEngineState = .idle
    private let stateQueue = DispatchQueue(label: "com.macpeq.audioEngine", qos: .userInitiated)
    private var deviceChangeListener: AudioObjectPropertyListenerProc?
    private var pendingRebuild = false
    

    
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
    
    // MARK: - Public API
    
    func start() -> Bool {
        Logger.info("Starting AudioEngine (CP3: device switching)")
        
        return stateQueue.sync {
            // Only valid from idle or disabled state (checked inside queue to avoid data race)
            guard self.state == .idle || self.state == .disabled else {
                Logger.warning("Cannot start from state: \(self.state)")
                return false
            }
            return self.performStart()
        }
    }
    
    private func performStart() -> Bool {
        state = .building
        Logger.info("State: building")
        
        // 1. Get default output device
        guard let defaultDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get default output device")
            state = .disabled
            return false
        }
        currentOutputDeviceID = defaultDeviceID
        Logger.info("Default output device", metadata: ["id": "\(defaultDeviceID)"])
        
        // Register device change listener (first time only)
        if deviceChangeListener == nil {
            registerDeviceChangeListener()
        }
        
        // 2. Create tap description
        guard createTap(for: defaultDeviceID) else {
            Logger.error("Failed to create audio tap")
            state = .disabled
            return false
        }
        
        // 3. Create aggregate device with tap
        guard createAggregateDevice() else {
            Logger.error("Failed to create aggregate device")
            cleanupTap()
            state = .disabled
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
            state = .disabled
            return false
        }
        
        // 6. Create AUHAL output unit (plays to default device)
        guard createAUHALOutput(defaultDeviceID: defaultDeviceID) else {
            Logger.error("Failed to create AUHAL output")
            cleanupIOProc()
            cleanupAggregateDevice()
            cleanupTap()
            state = .disabled
            return false
        }
        
        // 7. Start everything
        guard startAudio() else {
            Logger.error("Failed to start audio")
            cleanupAll()
            state = .disabled
            return false
        }
        
        state = .running
        isRunning = true
        Logger.info("State: running - AudioEngine started successfully")
        return true
    }
    
    func stop() {
        stateQueue.sync {
            guard state.isActive else { return }
            performStop()
        }
    }
    
    private func performStop() {
        Logger.info("Stopping AudioEngine (state was: \(state))")
        state = .tearingDown
        stopAudio()
        cleanupAll()
        state = .idle
        isRunning = false
        Logger.info("State: idle - AudioEngine stopped")
    }
    

    
    // MARK: - Device Change Handling
    
    private func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Create a persistent listener closure
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            // Dispatch to our serial queue - never handle on Core Audio thread
            AudioEngine.shared?.handleDeviceChange()
            return noErr
        }
        
        deviceChangeListener = listener
        
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listener,
            nil
        )
        
        if status == noErr {
            Logger.info("Registered default output device listener")
        } else {
            Logger.error("Failed to register device listener", metadata: ["status": "\(status)"])
        }
    }
    
    private func unregisterDeviceChangeListener() {
        guard let listener = deviceChangeListener else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listener,
            nil
        )
        
        deviceChangeListener = nil
        Logger.info("Unregistered default output device listener")
    }
    
    /// Called when default output device changes - on serial queue
    private func handleDeviceChange() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If we're already building/tearing down, queue a rebuild for after
            if self.state == .building || self.state == .tearingDown {
                self.pendingRebuild = true
                Logger.info("Rebuild in progress, queued pending device change")
                return
            }
            
            // Only rebuild if we're running
            guard self.state == .running else {
                Logger.info("Device change received but not running (state: \(self.state))")
                return
            }
            
            Logger.info("Device change detected - rebuilding audio pipeline")
            self.rebuildForNewDevice()
        }
    }
    
    /// Teardown and rebuild for new device - must be called on stateQueue
    private func rebuildForNewDevice() {
        state = .tearingDown
        Logger.info("State: tearingDown")
        
        // Stop AUHAL
        if let au = outputAU {
            AudioOutputUnitStop(au)
        }
        stopReadingFromAggregate()
        
        // Clear ring buffer to remove stale samples from old sample rate
        ringBuffer?.clear()
        Logger.info("Cleared ring buffer for device transition")
        
        // Cleanup (but don't unregister listener)
        cleanupIOProc()
        cleanupAUHAL()
        cleanupAggregateDevice()
        cleanupTap()
        
        // Check for new default device
        guard let newDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get new default output device")
            state = .disabled
            return
        }
        
        Logger.info("New default device", metadata: ["id": "\(newDeviceID)"])
        currentOutputDeviceID = newDeviceID
        
        // Rebuild
        state = .building
        Logger.info("State: building")
        
        guard createTap(for: newDeviceID) else {
            Logger.error("Failed to create tap for new device")
            state = .disabled
            return
        }
        
        guard createAggregateDevice() else {
            Logger.error("Failed to create aggregate for new device")
            cleanupTap()
            state = .disabled
            return
        }
        
        // Recreate ring buffer (sample rate may have changed)
        ringBuffer = RingBuffer(
            capacityFrames: ringBufferFrames,
            channels: Int(tapFormat.mChannelsPerFrame),
            bytesPerSample: Int(tapFormat.mBytesPerFrame / tapFormat.mChannelsPerFrame)
        )
        Logger.info("Recreated ring buffer", metadata: [
            "frames": "\(ringBufferFrames)",
            "channels": "\(tapFormat.mChannelsPerFrame)",
            "sampleRate": "\(Int(tapFormat.mSampleRate))"
        ])
        
        guard setupIOProc() else {
            Logger.error("Failed to setup IOProc for new device")
            cleanupAggregateDevice()
            cleanupTap()
            state = .disabled
            return
        }
        
        guard createAUHALOutput(defaultDeviceID: newDeviceID) else {
            Logger.error("Failed to create AUHAL for new device")
            cleanupIOProc()
            cleanupAggregateDevice()
            cleanupTap()
            state = .disabled
            return
        }
        
        guard startAudio() else {
            Logger.error("Failed to start audio for new device")
            cleanupAll()
            state = .disabled
            return
        }
        
        state = .running
        isRunning = true
        Logger.info("State: running - Rebuild complete, audio resumed on new device")
        
        // Process any pending rebuild from coalesced device changes
        // (state == .running here since we just set it above)
        if pendingRebuild {
            pendingRebuild = false
            Logger.info("Processing pending rebuild")
            rebuildForNewDevice()
        }
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
        
        // Validate format: CP1 only supports Float32 interleaved PCM
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            Logger.error("Unsupported tap format — expected Float32 PCM", metadata: [
                "formatID": "\(format.mFormatID)",
                "flags": "\(format.mFormatFlags)"
            ])
            return false
        }
        
        self.tapFormat = format
        Logger.info("Tap created", metadata: ["id": "\(tapID)"])
        return true
    }
    
    /// Error code 1852797029 = 'cmbe' = aggregate device with this UID already exists
    private let kAggregateDeviceExistsError: OSStatus = 1852797029
    
    /// Deterministic UID based on tap UID - enables crash recovery by matching
    /// aggregate device across sessions if cleanup failed. Uses tap UID directly
    /// since it's already unique per device/session.
    private func makeAggregateUID(tapUID: String) -> String {
        return "com.macpeq.aggregate.\(tapUID)"
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
        let tapUIDString = tapUIDCF as String
        
        let tapList: [[String: Any]] = [
            [
                kAudioSubTapUIDKey: tapUIDString,
                kAudioSubTapDriftCompensationKey: true
            ]
        ]
        
        // Use deterministic UID based on tapUID so we can recover from crashes
        let aggregateUID = makeAggregateUID(tapUID: tapUIDString)
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacPEQ",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: tapList,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        
        var status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        
        // Handle stale aggregate device (from previous crash - deterministic UID lets us find it)
        if status == kAggregateDeviceExistsError {
            Logger.warning("Aggregate device with UID exists - attempting cleanup", metadata: ["uid": aggregateUID])
            
            if destroyStaleAggregateDevice(uid: aggregateUID) {
                Logger.info("Destroyed stale aggregate device, retrying creation")
                status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
            }
        }
        
        guard status == noErr else {
            Logger.error("AudioHardwareCreateAggregateDevice failed", metadata: ["status": "\(status)"])
            return false
        }
        
        Logger.info("Aggregate device created", metadata: ["id": "\(aggregateDeviceID)"])
        return true
    }
    
    /// Look up aggregate device by UID and destroy it
    private func destroyStaleAggregateDevice(uid: String) -> Bool {
        // Translate UID to device ID
        var uidCF = uid as CFString
        var deviceID: AudioDeviceID = 0
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devicePtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<CFString>.size),
                    uidPtr,
                    &size,
                    devicePtr
                )
            }
        }
        
        guard status == noErr, deviceID != 0 else {
            Logger.error("Failed to translate UID to device", metadata: ["status": "\(status)"])
            return false
        }
        
        Logger.info("Found stale aggregate device", metadata: ["id": "\(deviceID)"])
        
        let destroyStatus = AudioHardwareDestroyAggregateDevice(deviceID)
        if destroyStatus == noErr {
            Logger.info("Destroyed stale aggregate device")
            return true
        } else {
            Logger.error("Failed to destroy stale aggregate device", metadata: ["status": "\(destroyStatus)"])
            return false
        }
    }
    
    private var ioProcID: AudioDeviceIOProcID?
    private var currentOutputDeviceID: AudioDeviceID = 0
    
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

    
    /// CP2: Initialize single biquad filter once sample rate is known
    /// Hardcoded: +6dB peak at 1kHz, Q=1.0
    private func initFilters(sampleRate: Float) {
        leftFilter = BiquadMath.makeFilter(
            type: .peak, frequency: 1000.0, gain: 6.0, q: 1.0, sampleRate: sampleRate
        )
        rightFilter = BiquadMath.makeFilter(
            type: .peak, frequency: 1000.0, gain: 6.0, q: 1.0, sampleRate: sampleRate
        )
        
        #if DEBUG
        if let f = leftFilter {
            Logger.debug("Filter coefficients", metadata: [
                "b0": "\(String(format: "%.6f", f.b0))",
                "b1": "\(String(format: "%.6f", f.b1))",
                "b2": "\(String(format: "%.6f", f.b2))",
                "a1": "\(String(format: "%.6f", f.a1))",
                "a2": "\(String(format: "%.6f", f.a2))"
            ])
        }
        #endif
        
        Logger.info("CP2: Single biquad filter active", metadata: [
            "type": "peak", "freq": "1000Hz", "gain": "+6dB", "q": "1.0", "rate": "\(Int(sampleRate))"
        ])
    }
    
    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        Logger.info("Creating AUHAL output unit")
        
        // Initialize filters with actual sample rate
        initFilters(sampleRate: Float(tapFormat.mSampleRate))
        
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
                "tapRate": "\(Int(tapFormat.mSampleRate))"
            ])
            if Int(outputRate) != Int(tapFormat.mSampleRate) {
                Logger.error("Sample rate mismatch — CP1 does not support conversion")
                return false
            }
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
    
    // Track consecutive render callbacks for logging
    private var renderCallbackCount = 0
    private var lastRenderLog: Date = Date.distantPast
    
    private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
        let requestedFrames = Int(frames)
        
        renderCallbackCount += 1
        

        
        // Log every 100th render callback to see the buffer size patterns
        let now = Date()
        if renderCallbackCount % 100 == 0 && now.timeIntervalSince(lastRenderLog) > 1.0 {
            Logger.info("AUHAL render callback", metadata: [
                "requestedFrames": "\(requestedFrames)",
                "callbackCount": "\(renderCallbackCount)"
            ])
            lastRenderLog = now
        }
        
        // CP2: Single biquad filter applied per-channel after reading from ring buffer
        // Handle both non-interleaved (separate buffer per channel) and interleaved (single buffer)
        var bufferIndex = 0
        for buffer in bufferList {
            guard buffer.mData != nil else { bufferIndex += 1; continue }
            
            let channelCount = Int(buffer.mNumberChannels)
            let dest = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            // Read from ring buffer into output buffer
            let readFrames = ringBuffer?.read(into: dest, frameCount: requestedFrames) ?? 0
            
            // Handle underrun: output silence (cleaner than sample repetition)
            if readFrames < requestedFrames {
                let zeroStart = readFrames * channelCount
                let zeroCount = (requestedFrames - readFrames) * channelCount
                memset(dest.advanced(by: zeroStart), 0, zeroCount * MemoryLayout<Float>.size)
            }
            
            // CP2: Apply single biquad filter per channel (if initialized, enabled, and we have data)
            if filterEnabled && readFrames > 0,
               var left = leftFilter, var right = rightFilter {
                if channelCount == 1 {
                    // Non-interleaved: separate buffer per channel
                    if bufferIndex == 0 {
                        left.processBuffer(dest, frameCount: readFrames)
                        leftFilter = left  // Save state back
                    } else if bufferIndex == 1 {
                        right.processBuffer(dest, frameCount: readFrames)
                        rightFilter = right  // Save state back
                    }
                } else if channelCount >= 2 {
                    // Interleaved: frame-by-frame processing (cache-friendly)
                    for frame in 0..<readFrames {
                        let idx = frame * channelCount
                        dest[idx]     = left.process(dest[idx])
                        dest[idx + 1] = right.process(dest[idx + 1])
                    }
                    leftFilter = left   // Save state back
                    rightFilter = right // Save state back
                }
            }
            bufferIndex += 1
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
        
        let fillLevel = ringBuffer?.fillLevel ?? 0
        Logger.info("Audio started", metadata: [
            "ringBufferFill": "\(fillLevel)",
            "ratio": "\(String(format: "%.2f", Float(fillLevel) / Float(ringBufferFrames)))"
        ])
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
        // Note: we don't unregister the listener here - it stays until app quits
    }
    
    deinit {
        // Unregister listener when engine is deallocated
        unregisterDeviceChangeListener()
        AudioEngine.shared = nil
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
