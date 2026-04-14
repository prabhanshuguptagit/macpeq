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
    
    // CP3: Pre-muted taps on all output devices.
    // Muted taps are created on every output device at startup so that when the system
    // switches default device, the new device is already muted — eliminating the "blip"
    // of raw audio that would otherwise play before our pipeline is rebuilt.
    private struct DeviceTapInfo {
        let deviceID: AudioDeviceID
        let deviceUID: String
        var tapID: AudioObjectID
    }
    private var deviceTaps: [AudioDeviceID: DeviceTapInfo] = [:]
    private var deviceListListener: AudioObjectPropertyListenerProc?
    
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
        
        // 2. Pre-create muted taps on ALL output devices
        // This ensures that when the system switches default device, the new device
        // is already muted — no blip of raw audio before our pipeline rebuilds.
        createTapsOnAllDevices()
        registerDeviceListListener()
        
        // 3. Build pipeline on default device using its pre-existing tap
        guard let tap = deviceTaps[defaultDeviceID] else {
            Logger.error("No pre-created tap for default device \(defaultDeviceID)")
            state = .disabled
            return false
        }
        tapID = tap.tapID
        
        // Read format from tap
        let fmtStatus = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat)
        guard fmtStatus == noErr else {
            Logger.error("Failed to get tap format")
            state = .disabled
            return false
        }
        
        // Validate format
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            Logger.error("Unsupported tap format — expected Float32 PCM")
            state = .disabled
            return false
        }
        
        Logger.info("Tap format", metadata: [
            "rate": "\(Int(tapFormat.mSampleRate))",
            "channels": "\(tapFormat.mChannelsPerFrame)"
        ])
        
        // 4. Create aggregate device with tap
        guard createAggregateDevice() else {
            Logger.error("Failed to create aggregate device")
            state = .disabled
            return false
        }
        
        // Re-read tap format after aggregate creation — the aggregate forces the tap
        // onto the device clock, so the rate may have updated. Then correct any
        // remaining stale rate against the device's nominal rate.
        rereadTapFormat()
        correctTapSampleRate(for: defaultDeviceID)
        
        // 5. Create ring buffer (using actual tap format)
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
        
        // 6. Setup IOProc on aggregate device
        guard setupIOProc() else {
            Logger.error("Failed to setup IOProc")
            cleanupAggregateDevice()
            state = .disabled
            return false
        }
        
        // 7. Create AUHAL output unit (plays to default device)
        guard createAUHALOutput(defaultDeviceID: defaultDeviceID) else {
            Logger.error("Failed to create AUHAL output")
            cleanupIOProc()
            cleanupAggregateDevice()
            state = .disabled
            return false
        }
        
        // 8. Start everything
        guard startAudio() else {
            Logger.error("Failed to start audio")
            cleanupPipeline()
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
    
    /// Called when default output device changes.
    /// Debounces by 50ms — macOS often fires multiple device change events in quick
    /// succession (e.g. intermediate device during a switch). Each new event resets
    /// the timer so we rebuild once for the final device.
    private var debounceWorkItem: DispatchWorkItem?
    
    private func handleDeviceChange() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending debounced rebuild
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            
            // Ignore if we're idle or disabled
            guard self.state == .running || self.state == .building || self.state == .tearingDown else {
                Logger.info("Device change received but not active (state: \(self.state))")
                return
            }
            
            Logger.info("Device change detected — debouncing 50ms")
            
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.debounceWorkItem = nil
                
                // If a rebuild is in progress, mark pending and let it handle the re-check
                if self.state == .building || self.state == .tearingDown {
                    self.pendingRebuild = true
                    Logger.info("Rebuild in progress when debounce fired, queued pending")
                    return
                }
                
                guard self.state == .running else {
                    Logger.info("State changed during debounce (state: \(self.state)), skipping rebuild")
                    return
                }
                
                self.rebuildForNewDevice()
            }
            self.debounceWorkItem = workItem
            self.stateQueue.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }
    
    /// Rebuild pipeline for new device using pre-existing muted tap.
    ///
    /// Because muted taps are pre-created on all output devices at startup, the new
    /// device is already muted when the system switches to it — no blip of raw audio.
    /// We only need to rebuild the aggregate + IOProc + AUHAL (taps persist).
    ///
    /// Must be called on stateQueue.
    private func rebuildForNewDevice() {
        // Check if the default device actually changed
        guard let newDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get new default output device")
            state = .disabled
            return
        }
        
        if newDeviceID == currentOutputDeviceID {
            Logger.info("Same device \(newDeviceID), skipping rebuild")
            pendingRebuild = false
            return
        }
        
        state = .tearingDown
        Logger.info("State: tearingDown")
        
        // Teardown pipeline (but NOT taps — they persist across device switches)
        stopAudio()
        cleanupPipeline()
        
        Logger.info("New default device", metadata: ["id": "\(newDeviceID)"])
        currentOutputDeviceID = newDeviceID
        
        // Find pre-existing tap for this device
        if deviceTaps[newDeviceID] == nil {
            Logger.warning("No pre-created tap for device \(newDeviceID) — creating one now")
            createTapForDevice(newDeviceID)
        }
        
        guard let tap = deviceTaps[newDeviceID] else {
            Logger.error("Failed to create tap for new device")
            state = .disabled
            return
        }
        
        tapID = tap.tapID
        Logger.info("Using pre-existing muted tap", metadata: ["tapID": "\(tapID)"])
        
        // Read format from tap for channel layout and PCM format info.
        // NOTE: The sample rate may be stale — the tap was created while a different
        // device was active. This is fine: we only use channel count and byte layout
        // from tapFormat. createAUHALOutput() reads the device's nominal sample rate
        // independently for the AUHAL stream format and filter initialization.
        let fmtStatus = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat)
        guard fmtStatus == noErr else {
            Logger.error("Failed to get tap format for new device")
            state = .disabled
            return
        }
        
        Logger.info("Tap format (rate may be stale)", metadata: [
            "rate": "\(Int(tapFormat.mSampleRate))",
            "channels": "\(tapFormat.mChannelsPerFrame)"
        ])
        
        // Rebuild pipeline
        state = .building
        Logger.info("State: building")
        
        guard createAggregateDevice() else {
            Logger.error("Failed to create aggregate for new device")
            state = .disabled
            return
        }
        
        // Re-read tap format after aggregate creation, then correct the sample rate.
        // Pre-created taps lock to the device clock at creation time — if the device
        // was inactive then, the tap may still report the old rate (e.g. 44100 for a
        // 48000 UMC). The aggregate doesn't always force an update. We read the
        // device's nominal rate directly and use that as the authoritative rate.
        rereadTapFormat()
        correctTapSampleRate(for: newDeviceID)
        
        // Recreate ring buffer (channel count / sample rate may have changed)
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
            state = .disabled
            return
        }
        
        guard createAUHALOutput(defaultDeviceID: newDeviceID) else {
            Logger.error("Failed to create AUHAL for new device")
            cleanupIOProc()
            cleanupAggregateDevice()
            state = .disabled
            return
        }
        
        guard startAudio() else {
            Logger.error("Failed to start audio for new device")
            cleanupPipeline()
            state = .disabled
            return
        }
        
        state = .running
        isRunning = true
        Logger.info("State: running - Audio resumed on new device")
        
        // Process any pending rebuild from coalesced device changes
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
    
    // MARK: - Pre-mute tap management
    
    /// Enumerate all output devices and create a muted tap on each.
    private func createTapsOnAllDevices() {
        let devices = getAllOutputDevices()
        Logger.info("Found \(devices.count) output devices for pre-mute")
        
        for (devID, devUID) in devices {
            createTapForDevice(devID, uid: devUID)
        }
        
        Logger.info("Pre-muted taps created", metadata: ["count": "\(deviceTaps.count)"])
    }
    
    /// Create a muted tap on a single device and store it in deviceTaps.
    @discardableResult
    private func createTapForDevice(_ deviceID: AudioDeviceID, uid: String? = nil) -> Bool {
        // Skip if we already have a tap for this device
        if deviceTaps[deviceID] != nil { return true }
        
        // Get UID if not provided
        let deviceUID: String
        if let uid = uid {
            deviceUID = uid
        } else {
            var uidCF: CFString = "" as CFString
            let status = withUnsafeMutablePointer(to: &uidCF) { ptr in
                getProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
            }
            guard status == noErr else { return false }
            deviceUID = uidCF as String
        }
        
        // Exclude MacPEQ's own process from the tap
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownProcessObject = translatePIDToProcessObject(ownPID)
        let excludedProcesses: [NSNumber] = ownProcessObject.map { [NSNumber(value: $0)] } ?? []
        
        let tapDesc = CATapDescription(
            __processes: excludedProcesses,
            andDeviceUID: deviceUID,
            withStream: 0
        )
        tapDesc.isPrivate = true
        tapDesc.name = "MacPEQ"
        tapDesc.isExclusive = true
        
        let canMute = ownProcessObject != nil
        tapDesc.muteBehavior = canMute ? .muted : .unmuted

        // DIAG: If canMute is false the tap won't silence the device — this is a
        // likely cause of a blip on switch. PID translation can fail if the process
        // object hasn't been registered with HAL yet (rare but possible at startup).
        if !canMute {
            Logger.warning("canMute=false — tap will NOT silence device, blip likely", metadata: [
                "deviceID": "\(deviceID)",
                "deviceUID": deviceUID,
                "ownPID": "\(ownPID)"
            ])
        } else {
            Logger.info("canMute=true", metadata: [
                "deviceID": "\(deviceID)",
                "deviceUID": deviceUID,
                "processObject": "\(ownProcessObject!)"
            ])
        }
        
        var newTapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr else {
            Logger.warning("Could not create tap for device", metadata: [
                "deviceUID": deviceUID,
                "status": "\(status)"
            ])
            return false
        }
        
        deviceTaps[deviceID] = DeviceTapInfo(
            deviceID: deviceID, deviceUID: deviceUID, tapID: newTapID
        )
        Logger.info("Pre-muted tap created", metadata: [
            "deviceID": "\(deviceID)",
            "deviceUID": deviceUID,
            "tapID": "\(newTapID)",
            "muted": "\(canMute)"
        ])
        return true
    }
    
    /// Get all output devices as (deviceID, deviceUID) pairs.
    private func getAllOutputDevices() -> [(AudioDeviceID, String)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
        
        var result: [(AudioDeviceID, String)] = []
        for devID in devices {
            // Check if device has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &streamSize)
            if streamSize == 0 { continue }
            
            // Get UID
            var uidCF: CFString = "" as CFString
            let uidStatus = withUnsafeMutablePointer(to: &uidCF) { ptr in
                getProperty(of: devID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
            }
            guard uidStatus == noErr else { continue }
            
            result.append((devID, uidCF as String))
        }
        return result
    }
    
    /// Listen for device list changes (hot-plug) and create taps on new devices.
    private func registerDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngine.shared?.handleDeviceListChange()
            return noErr
        }
        deviceListListener = listener
        
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listener,
            nil
        )
        if status == noErr {
            Logger.info("Registered device list change listener")
        }
    }
    
    private func unregisterDeviceListListener() {
        guard let listener = deviceListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, listener, nil
        )
        deviceListListener = nil
    }
    
    /// Called when devices are added/removed. Creates taps on any new output devices.
    private func handleDeviceListChange() {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            let devices = self.getAllOutputDevices()
            
            // Create taps on any new devices
            for (devID, devUID) in devices {
                if self.deviceTaps[devID] == nil {
                    self.createTapForDevice(devID, uid: devUID)
                }
            }
            
            // Clean up taps for removed devices (but not the active one)
            let currentDeviceIDs = Set(devices.map { $0.0 })
            for (devID, tap) in self.deviceTaps {
                if !currentDeviceIDs.contains(devID) && devID != self.currentOutputDeviceID {
                    AudioHardwareDestroyProcessTap(tap.tapID)
                    self.deviceTaps.removeValue(forKey: devID)
                    Logger.info("Removed tap for disconnected device", metadata: [
                        "deviceID": "\(devID)"
                    ])
                }
            }
        }
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
    
    /// Re-read tap format after aggregate creation.
    /// The aggregate device binds the tap to the output device's clock domain,
    /// which updates the tap's reported sample rate to match the actual device.
    /// Pre-created taps report a stale rate from whichever device was active at
    /// creation time; this call gets the real rate.
    private func rereadTapFormat() {
        var updatedFormat = AudioStreamBasicDescription()
        let status = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &updatedFormat)
        if status == noErr {
            let oldRate = Int(tapFormat.mSampleRate)
            let newRate = Int(updatedFormat.mSampleRate)
            tapFormat = updatedFormat
            if oldRate != newRate {
                Logger.info("Tap format updated after aggregate creation", metadata: [
                    "oldRate": "\(oldRate)",
                    "newRate": "\(newRate)",
                    "channels": "\(tapFormat.mChannelsPerFrame)"
                ])
            } else {
                Logger.info("Tap format confirmed after aggregate", metadata: [
                    "rate": "\(newRate)",
                    "channels": "\(tapFormat.mChannelsPerFrame)"
                ])
            }
        } else {
            Logger.warning("Failed to re-read tap format after aggregate", metadata: [
                "status": "\(status)"
            ])
            // Continue with the pre-aggregate format — it may still work
        }
    }
    
    /// Override tapFormat.mSampleRate with the device's actual nominal rate.
    ///
    /// Pre-created taps lock to the HAL clock of whichever device was active at
    /// creation time. Even after aggregate creation, kAudioTapPropertyFormat may
    /// still report the old rate. The device nominal rate is always authoritative —
    /// that's what the IOProc will actually deliver after the aggregate binds the tap.
    private func correctTapSampleRate(for deviceID: AudioDeviceID) {
        var deviceRate: Float64 = 0
        let status = getProperty(of: deviceID, selector: kAudioDevicePropertyNominalSampleRate, value: &deviceRate)
        guard status == noErr, deviceRate > 0 else {
            Logger.warning("correctTapSampleRate: could not read device nominal rate", metadata: [
                "deviceID": "\(deviceID)", "status": "\(status)"
            ])
            return
        }
        
        let tapRate = tapFormat.mSampleRate
        if Int(tapRate) != Int(deviceRate) {
            Logger.info("Correcting stale tap sample rate to device nominal rate", metadata: [
                "staleRate": "\(Int(tapRate))",
                "deviceRate": "\(Int(deviceRate))",
                "deviceID": "\(deviceID)"
            ])
            tapFormat.mSampleRate = deviceRate
            // mBytesPerFrame and mBytesPerPacket don't depend on sample rate for PCM,
            // so no other ASBD fields need updating.
        } else {
            Logger.info("Tap sample rate matches device nominal rate", metadata: [
                "rate": "\(Int(deviceRate))"
            ])
        }
    }

    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        Logger.info("Creating AUHAL output unit")
        
        // Two rates matter here:
        // 1. tapFormat.mSampleRate — what the tap actually delivers via IOProc into
        //    the ring buffer. This is what we feed AUHAL in the render callback.
        // 2. Device nominal rate — what the output hardware runs at.
        //
        // We tell AUHAL: "I'm feeding you data at tapRate." AUHAL knows the output
        // device rate and does sample rate conversion internally if they differ.
        //
        // For EQ filters, we use the tap rate too — the filter processes the data
        // as it exists in the ring buffer, before any SRC AUHAL may apply.
        
        var deviceRate: Float64 = 0
        let rateStatus = getProperty(of: defaultDeviceID, selector: kAudioDevicePropertyNominalSampleRate, value: &deviceRate)
        
        let tapRate = tapFormat.mSampleRate
        Logger.info("Sample rates", metadata: [
            "tapRate": "\(Int(tapRate))",
            "deviceRate": rateStatus == noErr ? "\(Int(deviceRate))" : "unknown"
        ])
        if rateStatus == noErr && Int(deviceRate) != Int(tapRate) {
            Logger.info("Tap and device rates differ — AUHAL will handle SRC")
        }

        // DIAG: Verify rereadTapFormat() gave us the real device rate.
        // If these differ after aggregate creation it means the tap format wasn't
        // updated correctly — the ring buffer will contain data at a different rate
        // than we're telling AUHAL, causing pitch shift / stutter on this device.
        if rateStatus == noErr && Int(tapRate) != Int(deviceRate) {
            Logger.warning("DIAG: tapRate != deviceRate after aggregate — possible SRC issue", metadata: [
                "tapRate": "\(Int(tapRate))",
                "deviceRate": "\(Int(deviceRate))",
                "deviceID": "\(defaultDeviceID)"
            ])
        }
        
        // Initialize filters at the tap's rate (data rate we process)
        initFilters(sampleRate: Float(tapRate))
        
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
        
        // Tell AUHAL the format of data we're feeding it: the tap format as-is.
        // This is the actual rate of samples in the ring buffer. AUHAL will do
        // sample rate conversion to the output device rate if they differ.
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
    private var renderCallbackCount: UInt64 = 0
    private var lastRenderLogTime: CFAbsoluteTime = 0
    
    private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
        let requestedFrames = Int(frames)
        
        renderCallbackCount &+= 1
        
        // Periodic logging — use CFAbsoluteTimeGetCurrent (no heap allocation)
        // instead of Date(). Only check time every 512th callback to minimize overhead.
        if renderCallbackCount & 511 == 0 {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastRenderLogTime > 2.0 {
                Logger.info("AUHAL render", metadata: [
                    "frames": "\(requestedFrames)",
                    "count": "\(renderCallbackCount)",
                    "fillLevel": "\(ringBuffer?.fillLevel ?? -1)"
                ])
                lastRenderLogTime = now
            }
        }
        
        // Cache ring buffer pointer to avoid repeated optional unwrap
        guard let rb = ringBuffer else {
            // No ring buffer — zero all output
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        
        // Process buffers. For stereo interleaved (the common case), we read once
        // and apply L/R filters inline. For non-interleaved, one buffer per channel.
        var bufferIndex = 0
        for buffer in bufferList {
            guard let data = buffer.mData else { bufferIndex += 1; continue }
            
            let channelCount = Int(buffer.mNumberChannels)
            let dest = data.assumingMemoryBound(to: Float.self)
            
            // Read from ring buffer
            let readFrames = rb.read(into: dest, frameCount: requestedFrames)
            
            // Zero any underrun tail
            if readFrames < requestedFrames {
                let zeroStart = readFrames * channelCount
                let zeroCount = (requestedFrames - readFrames) * channelCount
                memset(dest.advanced(by: zeroStart), 0, zeroCount * MemoryLayout<Float>.size)
            }
            
            // Apply biquad filter (skip if disabled or no data)
            if filterEnabled && readFrames > 0 {
                if channelCount == 1 {
                    // Non-interleaved: one buffer per channel
                    if bufferIndex == 0 {
                        leftFilter?.processBuffer(dest, frameCount: readFrames)
                    } else if bufferIndex == 1 {
                        rightFilter?.processBuffer(dest, frameCount: readFrames)
                    }
                    // Channels beyond stereo: pass through unfiltered
                } else if channelCount >= 2 {
                    // Interleaved stereo+: process L/R only, skip extra channels
                    if var left = leftFilter, var right = rightFilter {
                        for frame in 0..<readFrames {
                            let idx = frame * channelCount
                            dest[idx]     = left.process(dest[idx])
                            dest[idx + 1] = right.process(dest[idx + 1])
                        }
                        leftFilter = left
                        rightFilter = right
                    }
                }
            }
            bufferIndex += 1
        }
        
        return noErr
    }
    
    private func startAudio() -> Bool {
        // Start IOProc first — this fills the ring buffer from the tap
        startReadingFromAggregate()
        
        guard let au = outputAU else { return false }
        
        // Wait for the ring buffer to accumulate enough data before starting AUHAL.
        // Without this, the first render callbacks pull from an empty buffer causing
        // a burst of silence or tearing before the IOProc has filled enough data.
        // Target: ~10ms worth of samples (enough for one AUHAL render callback).
        let targetFrames = Int(tapFormat.mSampleRate * 0.01) // 10ms
        let maxWaitMs = 200  // safety cap
        let startTime = CFAbsoluteTimeGetCurrent()
        
        while (ringBuffer?.fillLevel ?? 0) < targetFrames {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > Double(maxWaitMs) {
                // DIAG: Hitting this on UMC→MacBook means the IOProc isn't filling the
                // ring buffer — likely the aggregate isn't delivering callbacks yet,
                // possibly because tapFormat.mSampleRate is wrong (stale pre-aggregate
                // rate) and the IOProc frame size math is off, or the aggregate itself
                // isn't running. Check "Aggregate device created" and "IOProc" logs
                // immediately above this for clues.
                Logger.warning("DIAG: Ring buffer pre-fill timeout — IOProc may not be delivering data", metadata: [
                    "fillLevel": "\(ringBuffer?.fillLevel ?? 0)",
                    "targetFrames": "\(targetFrames)",
                    "tapRate": "\(Int(tapFormat.mSampleRate))",
                    "elapsedMs": "\(Int(elapsed))"
                ])
                break
            }
            usleep(1000) // 1ms
        }
        
        let fillLevel = ringBuffer?.fillLevel ?? 0
        let waitMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        let timedOut = fillLevel < targetFrames
        Logger.info("Ring buffer pre-fill \(timedOut ? "TIMED OUT" : "OK")", metadata: [
            "fillLevel": "\(fillLevel)",
            "targetFrames": "\(targetFrames)",
            "waitMs": "\(waitMs)",
            "timedOut": "\(timedOut)"
        ])
        
        // Now start AUHAL — ring buffer has data ready
        let status = AudioOutputUnitStart(au)
        guard status == noErr else {
            Logger.error("AudioOutputUnitStart failed", metadata: ["status": "\(status)"])
            stopReadingFromAggregate()
            return false
        }
        
        Logger.info("Audio started")
        return true
    }
    
    private func stopAudio() {
        if let au = outputAU {
            AudioOutputUnitStop(au)
        }
        stopReadingFromAggregate()
    }
    
    /// Cleanup pipeline only (aggregate, IOProc, AUHAL, ring buffer).
    /// Taps are preserved for device switching.
    private func cleanupPipeline() {
        cleanupIOProc()
        cleanupAUHAL()
        cleanupAggregateDevice()
        ringBuffer = nil
    }
    
    /// Full cleanup including all pre-muted taps. Only used on stop/deinit.
    private func cleanupAll() {
        stopReadingFromAggregate()
        cleanupPipeline()
        
        // Destroy all pre-muted taps
        for (_, tap) in deviceTaps {
            AudioHardwareDestroyProcessTap(tap.tapID)
        }
        deviceTaps.removeAll()
        tapID = 0
        
        // Note: we don't unregister listeners here - they stay until deinit
    }
    
    deinit {
        unregisterDeviceChangeListener()
        unregisterDeviceListListener()
        // Destroy all pre-muted taps
        for (_, tap) in deviceTaps {
            AudioHardwareDestroyProcessTap(tap.tapID)
        }
        deviceTaps.removeAll()
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
    
    /// Note: Individual tap cleanup is no longer needed — taps persist in deviceTaps
    /// and are destroyed in cleanupAll() or deinit.
}
