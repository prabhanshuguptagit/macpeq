import CoreAudio
import AudioToolbox
import Foundation

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
    let engine = Unmanaged<AudioEngine>.fromOpaque(inClientData!).takeUnretainedValue()
    return engine.handleIOProc(inputData: inInputData, outputData: outOutputData)
}

/// System Tap → IOProc → RingBuffer → EQ → AUHAL Output → Default Device
///
/// Lifecycle (start/stop/rebuild) runs on a dedicated serial queue.
/// Real-time path (IOProc + AUHAL render) only touches ringBuffer + EQProcessor.
/// EQ parameter updates are double-buffered and atomic — safe from any thread.
@available(macOS 14.2, *)
final class AudioEngine {
    static weak var shared: AudioEngine?

    /// Dedicated serial queue for all audio lifecycle operations.
    let audioQueue = DispatchQueue(label: "com.macpeq.audio", qos: .userInitiated)

    init() {}

    private(set) var isRunning = false
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    private var ringBuffer: RingBuffer?
    private var tapFormat = AudioStreamBasicDescription()
    private let ringBufferFrames: Int32 = 32768
    private var currentOutputDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?

    private var scratchBuffer: UnsafeMutablePointer<Float>?
    private var scratchFrameCapacity: Int = 0
    private var scratchBufferSampleCount: Int = 0

    private let tapManager = DeviceTapManager()
    private var eqProcessor: EQProcessor?
    private var currentBands: [EQBand]?

    private var deviceChangeListener: AudioObjectPropertyListenerProc?
    private var debounceWorkItem: DispatchWorkItem?
    private var sampleRateListener: AudioObjectPropertyListenerProc?
    private var sampleRateListenerDeviceID: AudioDeviceID = 0

    // MARK: - Public API

    /// Start the engine. Safe to call from any thread.
    func start() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(audioQueue))
        var result = false
        let sem = DispatchSemaphore(value: 0)
        audioQueue.async { [weak self] in
            defer { sem.signal() }
            guard let self = self, !self.isRunning else { return }
            Logger.info("Starting AudioEngine")

            guard let defaultDeviceID = self.getDefaultOutputDevice() else { return }
            self.currentOutputDeviceID = defaultDeviceID
            self.registerSampleRateListener(for: defaultDeviceID)

            if self.deviceChangeListener == nil { self.registerDeviceChangeListener() }

            guard self.buildPipeline(deviceID: defaultDeviceID) else { return }

            self.isRunning = true
            Logger.info("AudioEngine started")
            result = true
        }
        sem.wait()
        return result
    }

    /// Stop the engine. Safe to call from any thread.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(audioQueue))
        let sem = DispatchSemaphore(value: 0)
        audioQueue.async { [weak self] in
            defer { sem.signal() }
            guard let self = self, self.isRunning else { return }
            Logger.info("Stopping AudioEngine")
            self.unregisterSampleRateListener()
            self.stopAudio()
            self.cleanupPipeline()
            self.tapID = 0
            self.isRunning = false
        }
        sem.wait()
    }

    /// Update EQ bands from the UI thread (or any thread). Double-buffered, lock-free.
    func updateEQ(bands: [EQBand]) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentBands = bands
            self.eqProcessor?.updateBands(bands)
        }
    }

    // MARK: - Pipeline Setup / Teardown

    private func buildPipeline(deviceID: AudioDeviceID) -> Bool {
        guard let tapID = tapManager.createTap(for: deviceID) else { return false }
        self.tapID = tapID

        guard getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat) == noErr else { return false }
        Logger.info("Tap format", metadata: [
            "sampleRate": "\(tapFormat.mSampleRate)",
            "channels": "\(tapFormat.mChannelsPerFrame)",
            "bits": "\(tapFormat.mBitsPerChannel)",
            "bytesPerFrame": "\(tapFormat.mBytesPerFrame)",
            "bytesPerPacket": "\(tapFormat.mBytesPerPacket)",
            "flags": "0x\(String(tapFormat.mFormatFlags, radix: 16))"
        ])
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return false }

        guard createAggregateDevice() else { return false }

        rereadTapFormat()

        // Scratch buffer for render callback (single read → EQ → distribute)
        let channels = Int(tapFormat.mChannelsPerFrame)
        let maxFramesPerCallback = 4096  // generous upper bound
        scratchFrameCapacity = maxFramesPerCallback
        scratchBufferSampleCount = maxFramesPerCallback * channels
        scratchBuffer = .allocate(capacity: scratchBufferSampleCount)
        scratchBuffer?.initialize(repeating: 0, count: scratchBufferSampleCount)

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

    private func rebuildForNewDevice() {
        guard isRunning else { return }
        guard let newDeviceID = getDefaultOutputDevice() else { isRunning = false; return }
        if newDeviceID == currentOutputDeviceID { return }

        stopAudio()
        cleanupPipeline()

        currentOutputDeviceID = newDeviceID
        registerSampleRateListener(for: newDeviceID)

        guard buildPipeline(deviceID: newDeviceID) else {
            setDeviceMute(newDeviceID, muted: false)
            isRunning = false; return
        }

        // Pipeline is running, tap is muted — safe to unmute the device
        setDeviceMute(newDeviceID, muted: false)
        Logger.info("Audio resumed on new device")
    }

    /// Mute/unmute a device's output. Falls back to volume if mute isn't supported.
    private func setDeviceMute(_ deviceID: AudioDeviceID, muted: Bool) {
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)

        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var mute: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &mute)
        } else {
            // Fallback: ramp volume to 0 / restore
            var volAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(deviceID, &volAddress) {
                var vol: Float32 = muted ? 0.0 : 1.0
                AudioObjectSetPropertyData(deviceID, &volAddress, 0, nil,
                    UInt32(MemoryLayout<Float32>.size), &vol)
            }
        }
    }

    // MARK: - Property Listeners

    private func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngine.shared?.handleDeviceChange()
            return noErr
        }
        deviceChangeListener = listener
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, listener, nil)
    }

    private func unregisterDeviceChangeListener() {
        guard let listener = deviceChangeListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, listener, nil)
        deviceChangeListener = nil
    }

    private func handleDeviceChange() {
        // Mute immediately on the CoreAudio listener thread — before debounce
        if let newDevice = getDefaultOutputDevice() {
            setDeviceMute(newDevice, muted: true)
        }

        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.debounceWorkItem = nil
                self.rebuildForNewDevice()
            }
            self.debounceWorkItem = workItem
            self.audioQueue.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }
    }

    private func registerSampleRateListener(for deviceID: AudioDeviceID) {
        unregisterSampleRateListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            AudioEngine.shared?.handleSampleRateChange()
            return noErr
        }
        sampleRateListener = listener
        sampleRateListenerDeviceID = deviceID
        AudioObjectAddPropertyListener(deviceID, &address, listener, nil)
    }

    private func unregisterSampleRateListener() {
        guard let listener = sampleRateListener, sampleRateListenerDeviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListener(sampleRateListenerDeviceID, &address, listener, nil)
        sampleRateListener = nil
        sampleRateListenerDeviceID = 0
    }

    private func handleSampleRateChange() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.currentOutputDeviceID = 0  // force rebuild to not short-circuit
            self.rebuildForNewDevice()
        }
    }

    // MARK: - Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        guard getProperty(of: AudioObjectID(kAudioObjectSystemObject),
                          selector: kAudioHardwarePropertyDefaultOutputDevice,
                          value: &deviceID) == noErr else { return nil }
        return deviceID
    }

    private func getProperty<T>(
        of objectID: AudioObjectID, selector: AudioObjectPropertySelector, value: inout T
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    }

    private func getProperty<T, Q>(
        of objectID: AudioObjectID, selector: AudioObjectPropertySelector,
        qualifier: inout Q, value: inout T
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(objectID, &address,
            UInt32(MemoryLayout<Q>.size), &qualifier, &size, &value)
    }

    // MARK: - Aggregate Device

    private let kAggregateDeviceExistsError: OSStatus = 1852797029

    private func makeAggregateUID(tapUID: String) -> String {
        return "com.macpeq.aggregate.\(tapUID)"
    }

    private func createAggregateDevice() -> Bool {
        var tapUIDCF: CFString = "" as CFString
        guard withUnsafeMutablePointer(to: &tapUIDCF, { ptr in
            getProperty(of: tapID, selector: kAudioTapPropertyUID, value: &ptr.pointee)
        }) == noErr else { return false }

        let tapUIDString = tapUIDCF as String
        let aggregateUID = makeAggregateUID(tapUID: tapUIDString)

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

        if status == kAggregateDeviceExistsError {
            if destroyStaleAggregateDevice(uid: aggregateUID) {
                status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
            }
        }

        return status == noErr
    }

    private func destroyStaleAggregateDevice(uid: String) -> Bool {
        var uidCF = uid as CFString
        var deviceID: AudioDeviceID = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devicePtr in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<CFString>.size), uidPtr, &size, devicePtr)
            }
        }
        guard status == noErr, deviceID != 0 else { return false }
        return AudioHardwareDestroyAggregateDevice(deviceID) == noErr
    }

    private func rereadTapFormat() {
        _ = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat)
    }

    // MARK: - IOProc

    private func setupIOProc() -> Bool {
        AudioDeviceCreateIOProcID(aggregateDeviceID, ioProcCallback,
            Unmanaged.passUnretained(self).toOpaque(), &ioProcID) == noErr
    }

    private let ioProcSettleCallbacks: Int32 = 4
    private var ioProcSettleCount: Int32 = 0

    private func startReadingFromAggregate() {
        guard let ioProcID = ioProcID else { return }
        AudioDeviceStart(aggregateDeviceID, ioProcID)
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

    func handleIOProc(inputData: UnsafePointer<AudioBufferList>,
                      outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        if OSAtomicDecrement32(&ioProcSettleCount) >= 0 { return noErr }

        let buffer = inputData.pointee.mBuffers
        let frames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
        ringBuffer?.write(buffer.mData!.assumingMemoryBound(to: Float.self), frameCount: frames)
        return noErr
    }

    // MARK: - AUHAL Output

    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        let channels = Int(tapFormat.mChannelsPerFrame)
        // Only EQ the first 2 channels (stereo). Extra channels pass through unmodified.
        guard let eq = EQProcessor(
            bandCount: 10,
            channelCount: min(channels, 2),
            sampleRate: Float(tapFormat.mSampleRate),
            maxFrames: scratchFrameCapacity
        ) else {
            Logger.error("Failed to create EQProcessor")
            return false
        }
        eqProcessor = eq

        // Re-apply previous EQ bands if we have them
        if let bands = currentBands {
            eq.updateBands(bands)
        }
        Logger.info("AUHAL format set", metadata: [
            "sampleRate": "\(tapFormat.mSampleRate)",
            "channels": "\(tapFormat.mChannelsPerFrame)",
            "bytesPerFrame": "\(tapFormat.mBytesPerFrame)"
        ])

        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

        guard let comp = AudioComponentFindNext(nil, &compDesc),
              AudioComponentInstanceNew(comp, &outputAU) == noErr,
              let au = outputAU else { return false }

        var deviceID = defaultDeviceID
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }

        var enable: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        enable = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))

        var format = tapFormat
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else { return false }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { inRefCon, _, _, _, inNumberFrames, ioData in
                let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                return engine.handleAUHALRender(frames: inNumberFrames, buffers: ioData!)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        guard AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else { return false }

        return AudioUnitInitialize(au) == noErr
    }

    private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
        let requestedFrames = Int(frames)

        guard let rb = ringBuffer, let scratch = scratchBuffer else {
            for buffer in bufferList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }

        let channels = Int(tapFormat.mChannelsPerFrame)
        let framesToRead = min(requestedFrames, scratchFrameCapacity)

        // 1. Single read from ring buffer into scratch (interleaved)
        let readFrames = rb.read(into: scratch, frameCount: framesToRead)

        // Zero any remaining frames in scratch
        if readFrames < framesToRead {
            let validSamples = readFrames * channels
            let totalSamples = framesToRead * channels
            memset(scratch.advanced(by: validSamples), 0,
                   (totalSamples - validSamples) * MemoryLayout<Float>.size)
        }

        // 2. Apply EQ in-place on scratch buffer
        if readFrames > 0, let eq = eqProcessor {
            eq.processInterleaved(buffer: scratch, frameCount: readFrames, channels: channels)
        }

        // 3. Distribute to output buffers
        if bufferList.count == 1, let data = bufferList[0].mData {
            // Interleaved output — straight copy
            memcpy(data, scratch, framesToRead * channels * MemoryLayout<Float>.size)
        } else {
            // Non-interleaved — deinterleave from scratch
            for ch in 0..<min(bufferList.count, channels) {
                guard let data = bufferList[ch].mData else { continue }
                let dest = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<framesToRead {
                    dest[frame] = scratch[frame * channels + ch]
                }
            }
        }

        return noErr
    }

    private func startAudio() -> Bool {
        ioProcSettleCount = ioProcSettleCallbacks
        startReadingFromAggregate()

        guard let au = outputAU else { return false }

        let targetFrames = Int(tapFormat.mSampleRate * 0.01)

        // First wait: let IOProc settle and tap stabilize
        let startTime = CFAbsoluteTimeGetCurrent()
        while (ringBuffer?.fillLevel ?? 0) < targetFrames {
            if (CFAbsoluteTimeGetCurrent() - startTime) * 1000 > 200 { break }
            usleep(1000)
        }

        // Discard settle/warm-up frames — may contain un-muted audio
        ringBuffer?.clear()

        // Second wait: refill with clean post-settle audio
        let refillStart = CFAbsoluteTimeGetCurrent()
        while (ringBuffer?.fillLevel ?? 0) < targetFrames {
            if (CFAbsoluteTimeGetCurrent() - refillStart) * 1000 > 200 { break }
            usleep(1000)
        }

        guard AudioOutputUnitStart(au) == noErr else {
            stopReadingFromAggregate(); return false
        }
        return true
    }

    private func stopAudio() {
        if let au = outputAU { AudioOutputUnitStop(au) }
        stopReadingFromAggregate()
    }

    private func cleanupAggregateDevice() {
        if aggregateDeviceID != 0 { AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0 }
    }

    private func cleanupPipeline() {
        cleanupIOProc()
        if let au = outputAU { AudioUnitUninitialize(au); AudioComponentInstanceDispose(au); outputAU = nil }
        cleanupAggregateDevice()
        if tapID != 0 {
            tapManager.destroyTap(tapID)
            tapID = 0
        }
        ringBuffer = nil
        if let ptr = scratchBuffer {
            ptr.deinitialize(count: scratchBufferSampleCount)
            ptr.deallocate()
            scratchBuffer = nil
        }
    }

    deinit {
        unregisterDeviceChangeListener()
        unregisterSampleRateListener()
        AudioEngine.shared = nil
    }
}
