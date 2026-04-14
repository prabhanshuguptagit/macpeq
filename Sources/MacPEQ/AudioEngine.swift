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
/// All state on main thread. Real-time path only touches ringBuffer + filters.
@available(macOS 14.2, *)
final class AudioEngine {
    static weak var shared: AudioEngine?

    init() { DeviceTapManager.shared = tapManager }

    private(set) var isRunning = false
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var outputAU: AudioUnit?
    private var ringBuffer: RingBuffer?
    private var tapFormat = AudioStreamBasicDescription()
    private let ringBufferFrames: Int32 = 32768
    private var currentOutputDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?



    private let tapManager = DeviceTapManager()
    private var leftFilter: BiquadFilter?
    private var rightFilter: BiquadFilter?

    private var deviceChangeListener: AudioObjectPropertyListenerProc?
    private var debounceWorkItem: DispatchWorkItem?
    private var sampleRateListener: AudioObjectPropertyListenerProc?
    private var sampleRateListenerDeviceID: AudioDeviceID = 0

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

    func start() -> Bool {
        guard !isRunning else { return false }
        Logger.info("Starting AudioEngine")

        guard let defaultDeviceID = getDefaultOutputDevice() else { return false }
        currentOutputDeviceID = defaultDeviceID
        registerSampleRateListener(for: defaultDeviceID)

        if deviceChangeListener == nil { registerDeviceChangeListener() }

        tapManager.activeDeviceID = defaultDeviceID
        tapManager.start()

        guard buildPipeline(deviceID: defaultDeviceID) else { return false }

        isRunning = true
        Logger.info("AudioEngine started")
        return true
    }

    func stop() {
        guard isRunning else { return }
        Logger.info("Stopping AudioEngine")
        unregisterSampleRateListener()
        stopAudio()
        cleanupPipeline()
        tapManager.stop()
        tapID = 0
        isRunning = false
    }

    private func buildPipeline(deviceID: AudioDeviceID) -> Bool {
        guard let tapID = tapManager.tapID(for: deviceID) else { return false }
        self.tapID = tapID

        guard getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat) == noErr else { return false }
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return false }

        guard createAggregateDevice() else { return false }

        rereadTapFormat()

        ringBuffer = RingBuffer(
            capacityFrames: ringBufferFrames,
            channels: Int(tapFormat.mChannelsPerFrame),
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

        let previousDeviceID = currentOutputDeviceID
        stopAudio()
        cleanupPipeline()

        currentOutputDeviceID = newDeviceID
        registerSampleRateListener(for: newDeviceID)
        tapManager.activeDeviceID = newDeviceID

        if newDeviceID == previousDeviceID {
            tapManager.destroyTap(for: newDeviceID)
        }

        guard buildPipeline(deviceID: newDeviceID) else {
            isRunning = false; return
        }
        Logger.info("Audio resumed on new device")
    }

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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.debounceWorkItem = nil
                self.rebuildForNewDevice()
            }
            self.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.currentOutputDeviceID = 0  // force rebuild to not short-circuit
            self.rebuildForNewDevice()
        }
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        guard getProperty(of: AudioObjectID(kAudioObjectSystemObject),
                          selector: kAudioHardwarePropertyDefaultOutputDevice,
                          value: &deviceID) == noErr else { return nil }
        return deviceID
    }

    /// 'cmbe' — aggregate device with this UID already exists
    private let kAggregateDeviceExistsError: OSStatus = 1852797029

    /// Deterministic UID based on tap UID — enables crash recovery
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

    /// Re-read tap format after aggregate creation — the aggregate forces the tap
    /// onto the device clock, so the rate may have updated.
    private func rereadTapFormat() {
        _ = getProperty(of: tapID, selector: kAudioTapPropertyFormat, value: &tapFormat)
    }

    private func setupIOProc() -> Bool {
        AudioDeviceCreateIOProcID(aggregateDeviceID, ioProcCallback,
            Unmanaged.passUnretained(self).toOpaque(), &ioProcID) == noErr
    }

    /// IOProc callbacks to discard after a rebuild (atomic, read on RT thread)
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

    /// Called by CoreAudio on a real-time thread. Writes tap audio into the ring buffer.
    func handleIOProc(inputData: UnsafePointer<AudioBufferList>,
                      outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        if OSAtomicDecrement32(&ioProcSettleCount) >= 0 { return noErr }

        let buffer = inputData.pointee.mBuffers
        let frames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
        ringBuffer?.write(buffer.mData!.assumingMemoryBound(to: Float.self), frameCount: frames)
        return noErr
    }

    private func initFilters(sampleRate: Float) {
        leftFilter = BiquadMath.makeFilter(type: .peak, frequency: 4000.0, gain: 10.0, q: 1.0, sampleRate: sampleRate)
        rightFilter = BiquadMath.makeFilter(type: .peak, frequency: 2000.0, gain: 10.0, q: 1.0, sampleRate: sampleRate)
    }

    private func createAUHALOutput(defaultDeviceID: AudioDeviceID) -> Bool {
        initFilters(sampleRate: Float(tapFormat.mSampleRate))

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

        guard let rb = ringBuffer else {
            for buffer in bufferList { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return noErr
        }

        var bufferIndex = 0
        for buffer in bufferList {
            guard let data = buffer.mData else { bufferIndex += 1; continue }
            let channelCount = Int(buffer.mNumberChannels)
            let dest = data.assumingMemoryBound(to: Float.self)
            let readFrames = rb.read(into: dest, frameCount: requestedFrames)

            if readFrames < requestedFrames {
                memset(dest.advanced(by: readFrames * channelCount), 0,
                       (requestedFrames - readFrames) * channelCount * MemoryLayout<Float>.size)
            }

            if readFrames > 0 {
                if channelCount == 1 {
                    if bufferIndex == 0 { leftFilter?.processBuffer(dest, frameCount: readFrames) }
                    else if bufferIndex == 1 { rightFilter?.processBuffer(dest, frameCount: readFrames) }
                } else if channelCount >= 2, var left = leftFilter, var right = rightFilter {
                    for frame in 0..<readFrames {
                        let idx = frame * channelCount
                        dest[idx] = left.process(dest[idx])
                        dest[idx + 1] = right.process(dest[idx + 1])
                    }
                    leftFilter = left; rightFilter = right
                }
            }
            bufferIndex += 1
        }
        return noErr
    }

    private func startAudio() -> Bool {
        OSAtomicCompareAndSwap32(ioProcSettleCount, ioProcSettleCallbacks, &ioProcSettleCount)
        startReadingFromAggregate()

        guard let au = outputAU else { return false }

        let targetFrames = Int(tapFormat.mSampleRate * 0.01)
        let startTime = CFAbsoluteTimeGetCurrent()
        while (ringBuffer?.fillLevel ?? 0) < targetFrames {
            if (CFAbsoluteTimeGetCurrent() - startTime) * 1000 > 200 { break }
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
        ringBuffer = nil
    }

    deinit {
        unregisterDeviceChangeListener()
        unregisterSampleRateListener()
        DeviceTapManager.shared = nil
        AudioEngine.shared = nil
    }
}
