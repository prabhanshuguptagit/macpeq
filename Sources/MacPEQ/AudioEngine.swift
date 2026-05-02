import CoreAudio
import AudioToolbox
import Foundation

/// System-wide audio capture-and-process pipeline.
///
/// The chain is: System Tap → Aggregate Device → IOProc → RingBuffer → EQ → AUHAL → Output.
/// The Tap captures everything other apps play. The Aggregate Device wraps the tap
/// so we can pull from it like a normal input device. The IOProc drains the aggregate
/// into a ring buffer. AUHAL pulls from the ring buffer on the output device's clock,
/// runs each block through the EQ, and hands it to the speakers.
///
/// Threading: lifecycle (start/stop/rebuild) runs on `audioQueue`. The render path
/// (IOProc + AUHAL) runs on CoreAudio's real-time threads and only touches
/// `ringBuffer`, `scratch`, and `eqProcessor`. EQ updates are double-buffered
/// inside `EQProcessor` so the UI thread never blocks the audio thread.
@available(macOS 14.2, *)
final class AudioEngine {
    /// The active engine. Set in `init`, used by C-style listener callbacks
    /// (which can't capture `self`) and by UI code that needs to reach the
    /// engine. Constructing a second engine replaces this reference.
    static var shared: AudioEngine?

    let audioQueue = DispatchQueue(label: "com.macpeq.audio", qos: .userInitiated)

    private(set) var isRunning = false

    // Pipeline state — only touched from `audioQueue`.
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    private var ioProcID: AudioDeviceIOProcID?
    private var ringBuffer: RingBuffer?
    private var scratch: ScratchBuffer?
    private var tapFormat = AudioStreamBasicDescription()
    private var currentOutputDeviceID: AudioDeviceID = 0
    private let ringBufferFrames: Int32 = 32_768

    private let tapManager = DeviceTapManager()
    private var eqProcessor: EQProcessor?
    private var currentBands: [EQBand]?  // last bands the UI gave us, for re-apply after rebuild

    // Property listeners.
    private var deviceChangeListener: AudioObjectPropertyListenerProc?
    private var debounceWorkItem: DispatchWorkItem?
    private var sampleRateListener: AudioObjectPropertyListenerProc?
    private var sampleRateListenerDeviceID: AudioDeviceID = 0

    // First few IOProc callbacks after startup can contain audio that wasn't
    // yet affected by the tap's mute behavior — drop them. Reason for the
    // delay isn't fully understood; 4 was determined empirically.
    private let ioProcSettleCallbacks: Int32 = 4
    private var ioProcSettleCount: Int32 = 0

    init() {
        AudioEngine.shared = self
    }

    deinit {
        unregisterDeviceChangeListener()
        unregisterSampleRateListener()
        if AudioEngine.shared === self { AudioEngine.shared = nil }
    }

    // MARK: - Public API

    /// Start the engine. Blocks until startup completes. Returns false if
    /// already running or if any pipeline stage failed to initialize.
    func start() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(audioQueue))
        return audioQueue.sync { startOnQueue() }
    }

    /// Stop the engine. Blocks until teardown completes.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(audioQueue))
        audioQueue.sync { stopOnQueue() }
    }

    /// Replace the active EQ band set. Safe to call from any thread.
    func updateEQ(bands: [EQBand]) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentBands = bands
            self.eqProcessor?.updateBands(bands)
        }
    }

    // MARK: - Lifecycle (on audioQueue)

    private func startOnQueue() -> Bool {
        guard !isRunning else { return false }
        Logger.info("Starting AudioEngine")

        guard let defaultDeviceID = getDefaultOutputDevice() else { return false }
        currentOutputDeviceID = defaultDeviceID
        registerSampleRateListener(for: defaultDeviceID)

        if deviceChangeListener == nil { registerDeviceChangeListener() }

        guard buildPipeline(deviceID: defaultDeviceID) else { return false }

        isRunning = true
        Logger.info("AudioEngine started")
        return true
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        Logger.info("Stopping AudioEngine")
        unregisterSampleRateListener()
        stopAudio()
        cleanupPipeline()
        isRunning = false
    }

    // MARK: - Pipeline build / teardown

    private func buildPipeline(deviceID: AudioDeviceID) -> Bool {
        guard let tapID = tapManager.createTap(for: deviceID) else { return false }
        self.tapID = tapID

        guard getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat) == noErr else {
            return false
        }
        Logger.info("Tap format", metadata: [
            "sampleRate": "\(tapFormat.mSampleRate)",
            "channels": "\(tapFormat.mChannelsPerFrame)",
            "bits": "\(tapFormat.mBitsPerChannel)",
            "bytesPerFrame": "\(tapFormat.mBytesPerFrame)",
            "flags": "0x\(String(tapFormat.mFormatFlags, radix: 16))"
        ])

        // We only handle float PCM; anything else would need a converter.
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return false }

        guard createAggregateDevice() else { return false }

        // Tap format can shift after the aggregate wraps it — re-read.
        _ = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat)

        let channels = Int(tapFormat.mChannelsPerFrame)
        // 4096 frames is well above any realistic AUHAL slice size.
        scratch = ScratchBuffer(frameCapacity: 4096, channels: channels)
        ringBuffer = RingBuffer(
            capacityFrames: ringBufferFrames,
            channels: channels,
            bytesPerSample: Int(tapFormat.mBytesPerFrame / tapFormat.mChannelsPerFrame))

        guard setupIOProc() else { cleanupAggregateDevice(); return false }
        guard createAUHALOutput(defaultDeviceID: deviceID) else {
            cleanupIOProc(); cleanupAggregateDevice(); return false
        }
        guard startAudio() else { cleanupPipeline(); return false }
        return true
    }

    private func cleanupPipeline() {
        cleanupIOProc()
        if let au = outputAU {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputAU = nil
        }
        cleanupAggregateDevice()
        if tapID != 0 { tapManager.destroyTap(tapID); tapID = 0 }
        ringBuffer = nil
        scratch = nil
    }

    /// Tear down and rebuild for the new default output device. Called from
    /// the device-change listener after debounce, and from the sample-rate
    /// listener with `force: true` (device unchanged but format changed).
    private func rebuildForNewDevice(force: Bool = false) {
        guard isRunning else { return }
        guard let newDeviceID = getDefaultOutputDevice() else { isRunning = false; return }
        if !force && newDeviceID == currentOutputDeviceID { return }

        stopAudio()
        cleanupPipeline()

        currentOutputDeviceID = newDeviceID
        registerSampleRateListener(for: newDeviceID)

        guard buildPipeline(deviceID: newDeviceID) else {
            setDeviceMute(newDeviceID, muted: false)
            isRunning = false
            return
        }

        // Pipeline is up; safe to unmute (handleDeviceChange muted pre-emptively).
        setDeviceMute(newDeviceID, muted: false)
        Logger.info("Audio resumed on new device")
    }

    // MARK: - Property listeners

    /// Build a property address for a global, main-element selector.
    private static func address(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func registerDeviceChangeListener() {
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngine.shared?.handleDeviceChange()
            return noErr
        }
        deviceChangeListener = listener
        var address = Self.address(for: kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, listener, nil)
    }

    private func unregisterDeviceChangeListener() {
        guard let listener = deviceChangeListener else { return }
        var address = Self.address(for: kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, listener, nil)
        deviceChangeListener = nil
    }

    private func handleDeviceChange() {
        // Mute on the listener thread *before* the debounce hop — otherwise
        // the user hears unprocessed audio for the ~50ms window.
        if let newDevice = getDefaultOutputDevice() {
            setDeviceMute(newDevice, muted: true)
        }

        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            // Debounce: device changes often arrive in bursts (plugging in
            // headphones can fire several notifications). Coalesce them.
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.debounceWorkItem = nil
                self.rebuildForNewDevice()
            }
            self.debounceWorkItem = workItem
            self.audioQueue.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    private func registerSampleRateListener(for deviceID: AudioDeviceID) {
        unregisterSampleRateListener()
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngine.shared?.handleSampleRateChange()
            return noErr
        }
        sampleRateListener = listener
        sampleRateListenerDeviceID = deviceID
        var address = Self.address(for: kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListener(deviceID, &address, listener, nil)
    }

    private func unregisterSampleRateListener() {
        guard let listener = sampleRateListener, sampleRateListenerDeviceID != 0 else { return }
        var address = Self.address(for: kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListener(sampleRateListenerDeviceID, &address, listener, nil)
        sampleRateListener = nil
        sampleRateListenerDeviceID = 0
    }

    private func handleSampleRateChange() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            // Device unchanged but format changed — bypass the equality check.
            self.rebuildForNewDevice(force: true)
        }
    }

    // MARK: - Aggregate device

    // FourCC 'nope' (0x6E6F7065) — returned when an aggregate device with
    // the given UID already exists, typically left over from a previous crash.
    private let kAggregateDeviceExistsError: OSStatus = 1_852_797_029

    private func createAggregateDevice() -> Bool {
        var tapUIDCF: CFString = "" as CFString
        guard getProperty(of: tapID, selector: kAudioTapPropertyUID, value: &tapUIDCF) == noErr else {
            return false
        }

        let tapUIDString = tapUIDCF as String
        let aggregateUID = "com.macpeq.aggregate.\(tapUIDString)"

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacPEQ",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUIDString, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]

        var status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)

        if status == kAggregateDeviceExistsError, destroyStaleAggregateDevice(uid: aggregateUID) {
            status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        }

        return status == noErr
    }

    private func destroyStaleAggregateDevice(uid: String) -> Bool {
        var uidCF = uid as CFString
        var deviceID: AudioDeviceID = 0
        guard getProperty(of: AudioObjectID(kAudioObjectSystemObject),
                          selector: kAudioHardwarePropertyTranslateUIDToDevice,
                          qualifier: &uidCF, value: &deviceID) == noErr,
              deviceID != 0 else { return false }
        return AudioHardwareDestroyAggregateDevice(deviceID) == noErr
    }

    private func cleanupAggregateDevice() {
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    // MARK: - IOProc (real-time path: aggregate device → ring buffer)

    private func setupIOProc() -> Bool {
        AudioDeviceCreateIOProcID(aggregateDeviceID, AudioEngine.ioProcCallback,
            Unmanaged.passUnretained(self).toOpaque(), &ioProcID) == noErr
    }

    /// CoreAudio invokes this on its own real-time thread. Bounce through to
    /// the engine instance via the opaque pointer set up in `setupIOProc`.
    private static let ioProcCallback: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, inClientData in
        let engine = Unmanaged<AudioEngine>.fromOpaque(inClientData!).takeUnretainedValue()
        return engine.handleIOProc(inputData: inInputData, outputData: outOutputData)
    }

    private func cleanupIOProc() {
        if let ioProcID = ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
    }

    fileprivate func handleIOProc(inputData: UnsafePointer<AudioBufferList>,
                                  outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        // Drop the first few callbacks (see ioProcSettleCallbacks declaration).
        if OSAtomicDecrement32(&ioProcSettleCount) >= 0 { return noErr }

        let buffer = inputData.pointee.mBuffers
        let frames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
        ringBuffer?.write(buffer.mData!.assumingMemoryBound(to: Float.self), frameCount: frames)
        return noErr
    }

    // MARK: - AUHAL (real-time path: ring buffer → EQ → output device)

    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        let channels = Int(tapFormat.mChannelsPerFrame)
        // EQ only the first 2 channels; anything beyond stereo passes through.
        eqProcessor = EQProcessor(
            bandCount: 10,
            channelCount: min(channels, 2),
            sampleRate: Float(tapFormat.mSampleRate))

        if let bands = currentBands { eqProcessor?.updateBands(bands) }

        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)

        guard let comp = AudioComponentFindNext(nil, &compDesc),
              AudioComponentInstanceNew(comp, &outputAU) == noErr,
              let au = outputAU else { return false }

        var deviceID = defaultDeviceID
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }

        // AUHAL can do both input and output; we only want output.
        var enable: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        enable = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))

        var format = tapFormat
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else { return false }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { inRefCon, _, _, _, inNumberFrames, ioData in
                let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                return engine.handleAUHALRender(frames: inNumberFrames, buffers: ioData!)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        guard AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else { return false }

        return AudioUnitInitialize(au) == noErr
    }

    private func handleAUHALRender(frames: UInt32,
                                   buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
        let requestedFrames = Int(frames)

        // If pipeline isn't ready, output silence (not garbage from uninit memory).
        guard let rb = ringBuffer, let scratch = scratch else {
            for buffer in bufferList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }

        let channels = Int(tapFormat.mChannelsPerFrame)
        let framesToRead = min(requestedFrames, scratch.frameCapacity)
        let readFrames = rb.read(into: scratch.pointer, frameCount: framesToRead)

        // Underrun: zero the unfilled tail so we emit silence, not stale samples.
        if readFrames < framesToRead {
            let validSamples = readFrames * channels
            let totalSamples = framesToRead * channels
            memset(scratch.pointer.advanced(by: validSamples), 0,
                   (totalSamples - validSamples) * MemoryLayout<Float>.size)
        }

        if readFrames > 0, let eq = eqProcessor {
            eq.processInterleaved(buffer: scratch.pointer, frameCount: readFrames, channels: channels)
        }

        // Output is either one interleaved buffer or N non-interleaved ones.
        if bufferList.count == 1, let data = bufferList[0].mData {
            memcpy(data, scratch.pointer, framesToRead * channels * MemoryLayout<Float>.size)
        } else {
            for ch in 0..<min(bufferList.count, channels) {
                guard let data = bufferList[ch].mData else { continue }
                let dest = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<framesToRead {
                    dest[frame] = scratch.pointer[frame * channels + ch]
                }
            }
        }

        return noErr
    }

    // MARK: - Audio start / stop

    private func startAudio() -> Bool {
        ioProcSettleCount = ioProcSettleCallbacks
        if let ioProcID = ioProcID { AudioDeviceStart(aggregateDeviceID, ioProcID) }

        guard let au = outputAU else { return false }

        // ~10ms of audio buffered before AU starts pulling, so it doesn't underrun.
        let targetFrames = Int(tapFormat.mSampleRate * 0.01)

        // First fill: settle the IOProc (early callbacks may include un-muted audio).
        waitForRingBuffer(targetFrames: targetFrames)

        // Discard warm-up audio and refill with clean post-settle frames.
        ringBuffer?.clear()
        waitForRingBuffer(targetFrames: targetFrames)

        guard AudioOutputUnitStart(au) == noErr else {
            if let ioProcID = ioProcID { AudioDeviceStop(aggregateDeviceID, ioProcID) }
            return false
        }
        return true
    }

    private func stopAudio() {
        if let au = outputAU { AudioOutputUnitStop(au) }
        if let ioProcID = ioProcID { AudioDeviceStop(aggregateDeviceID, ioProcID) }
    }

    /// Spin-wait until the ring buffer has `targetFrames` or `timeoutMs` elapses.
    /// Used during startup only — never called from the real-time path.
    private func waitForRingBuffer(targetFrames: Int, timeoutMs: Double = 200) {
        let start = CFAbsoluteTimeGetCurrent()
        while (ringBuffer?.fillLevel ?? 0) < targetFrames {
            if (CFAbsoluteTimeGetCurrent() - start) * 1000 > timeoutMs { return }
            usleep(1000)
        }
    }
}
