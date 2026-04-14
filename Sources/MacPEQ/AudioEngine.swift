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
/// System Tap → IOProc → RingBuffer → EQ Processing → AUHAL Output → Default Device
///
/// All state is managed on the main thread. No queues, no locks, no state machine.
/// The real-time audio path (IOProc + AUHAL render) only touches the ring buffer
/// and biquad filters, which are stable while isRunning == true.
@available(macOS 14.2, *)
final class AudioEngine {
    // Shared instance for C callback routing (CoreAudio property listeners
    // are C function pointers that can't capture context).
    static weak var shared: AudioEngine?

    init() {
        assert(AudioEngine.shared == nil, "AudioEngine is a singleton - only one instance allowed")
        DeviceTapManager.shared = tapManager
    }

    // MARK: - Pipeline State (main-thread only)

    /// The only state: are we running or not?
    /// Rebuilds happen in-place (stop → teardown → rebuild → start) with isRunning
    /// staying true throughout, since a rebuild is a transient internal operation.
    private(set) var isRunning = false

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    private var ringBuffer: RingBuffer?
    private var tapFormat = AudioStreamBasicDescription()
    private let ringBufferFrames: Int32 = 32768
    private var currentOutputDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?

    /// Number of IOProc callbacks to discard after a pipeline rebuild.
    /// CoreAudio's internal graph takes a few cycles to stabilize after
    /// creating a new aggregate device; the first callbacks can deliver
    /// partial or discontinuous audio that causes audible glitches.
    /// Accessed from the IOProc (real-time) thread — use atomic semantics.
    private let ioProcSettleCallbacks = 4
    private var ioProcSettleCount: Int32 = 0

    // Pre-muted tap management (handles taps on all devices, hot-plug, etc.)
    private let tapManager = DeviceTapManager()

    // CP2: Single biquad filter per channel
    private var leftFilter: BiquadFilter?
    private var rightFilter: BiquadFilter?
    private var filterEnabled: Bool = true

    // Device change handling
    private var deviceChangeListener: AudioObjectPropertyListenerProc?
    private var debounceWorkItem: DispatchWorkItem?

    // Sample rate change listener
    private var sampleRateListener: AudioObjectPropertyListenerProc?
    private var sampleRateListenerDeviceID: AudioDeviceID = 0

    // MARK: - CoreAudio Property Helpers

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

    /// Start the audio pipeline. Must be called on main thread.
    func start() -> Bool {
        assertMain()
        guard !isRunning else {
            Logger.warning("Already running, ignoring start()")
            return false
        }
        return performStart()
    }

    /// Stop the audio pipeline. Must be called on main thread.
    func stop() {
        assertMain()
        guard isRunning else { return }
        performStop()
    }

    // MARK: - Start / Stop

    private func performStart() -> Bool {
        Logger.info("Starting AudioEngine")

        // 1. Get default output device
        guard let defaultDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get default output device")
            return false
        }
        currentOutputDeviceID = defaultDeviceID
        registerSampleRateListener(for: defaultDeviceID)
        Logger.info("Default output device", metadata: ["id": "\(defaultDeviceID)"])

        // Register device change listener (first time only)
        if deviceChangeListener == nil {
            registerDeviceChangeListener()
        }

        // 2. Pre-create muted taps on ALL output devices
        tapManager.activeDeviceID = defaultDeviceID
        tapManager.start()

        // 3. Build pipeline on default device using its pre-existing tap
        guard buildPipeline(deviceID: defaultDeviceID) else {
            return false
        }

        isRunning = true
        Logger.info("AudioEngine started successfully")
        return true
    }

    private func performStop() {
        Logger.info("Stopping AudioEngine")
        unregisterSampleRateListener()
        stopAudio()
        cleanupAll()
        isRunning = false
        Logger.info("AudioEngine stopped")
    }

    // MARK: - Pipeline Build / Rebuild

    /// Build the full pipeline (aggregate + IOProc + AUHAL + ring buffer) for a device.
    /// On success, audio is running. On failure, partial cleanup is done.
    /// Caller sets isRunning appropriately.
    private func buildPipeline(deviceID: AudioDeviceID) -> Bool {
        // Get tap for this device
        guard let tapID = tapManager.tapID(for: deviceID) else {
            Logger.error("No tap for device \(deviceID)")
            return false
        }
        self.tapID = tapID

        // Read format from tap
        let fmtStatus = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat)
        guard fmtStatus == noErr else {
            Logger.error("Failed to get tap format")
            return false
        }

        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            Logger.error("Unsupported tap format — expected Float32 PCM")
            return false
        }

        Logger.info("Tap format", metadata: [
            "rate": "\(Int(tapFormat.mSampleRate))",
            "channels": "\(tapFormat.mChannelsPerFrame)"
        ])

        // Create aggregate device with tap
        guard createAggregateDevice() else {
            Logger.error("Failed to create aggregate device")
            return false
        }

        // Re-read tap format after aggregate creation — the aggregate forces the tap
        // onto the device clock, so the rate may have updated.
        rereadTapFormat()

        // Create ring buffer
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

        // Setup IOProc on aggregate device
        guard setupIOProc() else {
            Logger.error("Failed to setup IOProc")
            cleanupAggregateDevice()
            return false
        }

        // Create AUHAL output unit
        guard createAUHALOutput(defaultDeviceID: deviceID) else {
            Logger.error("Failed to create AUHAL output")
            cleanupIOProc()
            cleanupAggregateDevice()
            return false
        }

        // Start audio
        guard startAudio() else {
            Logger.error("Failed to start audio")
            cleanupPipeline()
            return false
        }

        return true
    }

    /// Rebuild pipeline for new device using pre-existing muted tap.
    ///
    /// Because muted taps are pre-created on all output devices at startup, the new
    /// device is already muted when the system switches to it — no blip of raw audio.
    /// We only need to rebuild the aggregate + IOProc + AUHAL (taps persist).
    ///
    /// Runs on main thread. isRunning stays true throughout (rebuild is transient).
    private func rebuildForNewDevice() {
        guard isRunning else { return }

        guard let newDeviceID = getDefaultOutputDevice() else {
            Logger.error("Failed to get new default output device")
            isRunning = false
            return
        }

        if newDeviceID == currentOutputDeviceID {
            Logger.info("Same device \(newDeviceID), skipping rebuild")
            return
        }

        let previousDeviceID = currentOutputDeviceID

        // Stop audio I/O (taps persist across device switches)
        stopAudio()
        cleanupPipeline()

        Logger.info("New default device", metadata: ["id": "\(newDeviceID)"])
        currentOutputDeviceID = newDeviceID
        registerSampleRateListener(for: newDeviceID)
        tapManager.activeDeviceID = newDeviceID

        // If rebuilding for same device (e.g. sample rate change), destroy the stale tap
        // so it gets recreated with the updated format.
        if newDeviceID == previousDeviceID {
            Logger.info("Recreating tap for same device (sample rate change)", metadata: [
                "deviceID": "\(newDeviceID)"
            ])
            tapManager.destroyTap(for: newDeviceID)
        }

        // Rebuild pipeline — isRunning stays true, rebuild is transient
        guard buildPipeline(deviceID: newDeviceID) else {
            isRunning = false
            Logger.error("Rebuild failed, engine stopped")
            return
        }

        Logger.info("Audio resumed on new device")
    }

    // MARK: - Device Change Handling

    private func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
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

    /// Called from CoreAudio callback thread. Debounces 50ms on main thread.
    /// macOS often fires multiple device change events in quick succession;
    /// each new event resets the timer so we rebuild once for the final device.
    private func handleDeviceChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            self.debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.debounceWorkItem = nil
                self.rebuildForNewDevice()
            }
            self.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    // MARK: - Sample Rate Change Handling

    private func registerSampleRateListener(for deviceID: AudioDeviceID) {
        unregisterSampleRateListener()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngine.shared?.handleSampleRateChange()
            return noErr
        }
        sampleRateListener = listener
        sampleRateListenerDeviceID = deviceID
        AudioObjectAddPropertyListener(deviceID, &address, listener, nil)
        Logger.info("Registered sample rate listener", metadata: ["deviceID": "\(deviceID)"])
    }

    private func unregisterSampleRateListener() {
        guard let listener = sampleRateListener, sampleRateListenerDeviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(sampleRateListenerDeviceID, &address, listener, nil)
        sampleRateListener = nil
        sampleRateListenerDeviceID = 0
        Logger.info("Unregistered sample rate listener")
    }

    /// Called when the nominal sample rate changes on the current output device.
    /// Zeroes currentOutputDeviceID to force rebuildForNewDevice() not to short-circuit.
    private func handleSampleRateChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            Logger.info("Sample rate changed — forcing pipeline rebuild")
            self.currentOutputDeviceID = 0  // force rebuildForNewDevice to not short-circuit
            self.rebuildForNewDevice()
        }
    }

    // MARK: - Setup Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        let status = getProperty(of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, value: &deviceID)
        guard status == noErr else {
            Logger.error("AudioObjectGetPropertyData failed", metadata: ["status": "\(status)"])
            return nil
        }
        return deviceID
    }

    /// Error code 1852797029 = 'cmbe' = aggregate device with this UID already exists
    private let kAggregateDeviceExistsError: OSStatus = 1852797029

    /// Deterministic UID based on tap UID - enables crash recovery by matching
    /// aggregate device across sessions if cleanup failed.
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

        let tapUIDString = tapUIDCF as String

        let tapList: [[String: Any]] = [
            [
                kAudioSubTapUIDKey: tapUIDString,
                kAudioSubTapDriftCompensationKey: true
            ]
        ]

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
        // Discard the first few callbacks after a rebuild while CoreAudio stabilizes.
        // Atomic decrement: if count > 0, skip this callback.
        let remaining = OSAtomicDecrement32(&ioProcSettleCount)
        if remaining >= 0 {
            return noErr
        }
        // Clamp at -1 to avoid underflow on long-running sessions
        if remaining < -1 {
            OSAtomicCompareAndSwap32(remaining, -1, &ioProcSettleCount)
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        )
        guard bufferList.count > 0 else { return noErr }

        for buffer in bufferList {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { continue }

            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            let frameCount = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
            ringBuffer?.write(samples, frameCount: frameCount)
        }
        return noErr
    }

    /// CP2: Initialize single biquad filter once sample rate is known
    private func initFilters(sampleRate: Float) {
        leftFilter = BiquadMath.makeFilter(
            type: .peak, frequency: 4000.0, gain: 10.0, q: 1.0, sampleRate: sampleRate
        )
        rightFilter = BiquadMath.makeFilter(
            type: .peak, frequency: 2000.0, gain: 10.0, q: 1.0, sampleRate: sampleRate
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
        }
    }

    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        Logger.info("Creating AUHAL output unit")

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
        var format = tapFormat

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

        // Set render callback
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

        // Periodic logging
        if renderCallbackCount & 511 == 0 {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastRenderLogTime > 2.0 {
                Logger.info("AUHAL render", metadata: [
                    "frames": "\(requestedFrames)",
                    "count": "\(renderCallbackCount)"
                ])
                lastRenderLogTime = now
            }
        }

        guard let rb = ringBuffer else {
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }

        var bufferIndex = 0
        for buffer in bufferList {
            guard let data = buffer.mData else { bufferIndex += 1; continue }

            let channelCount = Int(buffer.mNumberChannels)
            let dest = data.assumingMemoryBound(to: Float.self)

            let readFrames = rb.read(into: dest, frameCount: requestedFrames)

            if readFrames < requestedFrames {
                let zeroStart = readFrames * channelCount
                let zeroCount = (requestedFrames - readFrames) * channelCount
                memset(dest.advanced(by: zeroStart), 0, zeroCount * MemoryLayout<Float>.size)
            }

            if filterEnabled && readFrames > 0 {
                if channelCount == 1 {
                    if bufferIndex == 0 {
                        leftFilter?.processBuffer(dest, frameCount: readFrames)
                    } else if bufferIndex == 1 {
                        rightFilter?.processBuffer(dest, frameCount: readFrames)
                    }
                } else if channelCount >= 2 {
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
        // Arm the settle counter
        OSAtomicCompareAndSwap32(ioProcSettleCount, Int32(ioProcSettleCallbacks), &ioProcSettleCount)

        // Start IOProc first — this fills the ring buffer from the tap
        startReadingFromAggregate()

        guard let au = outputAU else { return false }

        // Wait for the ring buffer to accumulate enough data before starting AUHAL.
        let targetFrames = Int(tapFormat.mSampleRate * 0.01) // 10ms
        let maxWaitMs = 200
        let startTime = CFAbsoluteTimeGetCurrent()

        while (ringBuffer?.fillLevel ?? 0) < targetFrames {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > Double(maxWaitMs) {
                Logger.warning("Ring buffer pre-fill timeout", metadata: [
                    "fillLevel": "\(ringBuffer?.fillLevel ?? 0)",
                    "targetFrames": "\(targetFrames)",
                    "elapsedMs": "\(Int(elapsed))"
                ])
                break
            }
            usleep(1000) // 1ms
        }

        let fillLevel = ringBuffer?.fillLevel ?? 0
        let waitMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        Logger.info("Ring buffer pre-filled", metadata: [
            "fillLevel": "\(fillLevel)",
            "targetFrames": "\(targetFrames)",
            "waitMs": "\(waitMs)"
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
        tapManager.stop()
        tapID = 0
    }

    deinit {
        unregisterDeviceChangeListener()
        unregisterSampleRateListener()
        DeviceTapManager.shared = nil
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

    // MARK: - Debug Helpers

    private func assertMain() {
        assert(Thread.isMainThread, "AudioEngine methods must be called on main thread")
    }
}
