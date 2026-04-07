import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import ObjectiveC

enum AudioEngineState: Equatable {
    case idle
    case building
    case running
    case tearingDown
    case disabled
}

@available(macOS 14.2, *)
@MainActor
class AudioEngine: ObservableObject {
    @Published var state: AudioEngineState = .idle
    @Published var lastError: String?

    private let worker = AudioEngineWorker()

    var stateDescription: String {
        switch state {
        case .idle: return "Idle"
        case .building: return "Building…"
        case .running: return "Running"
        case .tearingDown: return "Tearing Down…"
        case .disabled: return "Disabled"
        }
    }

    func start() {
        guard state == .idle || state == .disabled else { return }
        state = .building
        lastError = nil
        worker.build { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.state = .running
                    logMessage("[AudioEngine] Running")
                case .failure(let err):
                    self.state = .disabled
                    self.lastError = err.localizedDescription
                    logMessage("[AudioEngine] Failed: \(err)")
                }
            }
        }
    }

    func stop() {
        guard state == .running else { return }
        state = .tearingDown
        worker.tearDown {
            Task { @MainActor in
                self.state = .idle
                logMessage("[AudioEngine] Stopped")
            }
        }
    }
}

// MARK: - Worker (off main thread)

@available(macOS 14.2, *)
class AudioEngineWorker {
    let queue = DispatchQueue(label: "com.macpeq.audioengine", qos: .userInitiated)

    // Core Audio objects
    private var tapID: AudioObjectID = 0
    private var tapDescription: CATapDescription?
    private var aggregateDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    // AUHAL removed for CP1 — using aggregate device IOProc for direct passthrough
    var ringBuffer = RingBuffer()
    var tapBytesPerFrame: Int = 0
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    // Monitoring
    var tapCallbackCount: UInt64 = 0
    var renderCallbackCount: UInt64 = 0
    var ioProcDebugInCount: Int32 = 0
    var ioProcDebugOutCount: Int32 = 0
    var ioProcDebugInBytes: Int32 = 0
    var ioProcDebugOutBytes: Int32 = 0
    var ioProcPeakLevel: Float = 0
    var ioProcPeakOut: Float = 0
    private var monitorTimer: DispatchSourceTimer?

    // Pending rebuild flag
    private var pendingRebuild = false
    private var isRebuilding = false

    func build(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                try self.buildSync()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func tearDown(completion: @escaping () -> Void) {
        queue.async { [self] in
            self.tearDownSync()
            completion()
        }
    }

    // MARK: - Build

    private func buildSync() throws {
        // 1. Get default output device
        let outputDeviceID = try getDefaultOutputDevice()
        let outputName = getDeviceName(outputDeviceID)
        logMessage("[Build] Default output device: \(outputDeviceID) (\(outputName))")

        // 2. Get output device sample rate
        let outputSampleRate = try getDeviceSampleRate(outputDeviceID)
        logMessage("[Build] Output device sample rate: \(outputSampleRate)")

        // 3. Create process tap
        // Note: exclude list takes AudioObjectIDs, not PIDs. Using empty list for now.
        // Self-exclusion is less critical since MacPEQ doesn't produce audio.
        logMessage("[Build] Creating tap")
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        logMessage("[Build] Tap description created, UUID: \(tap.uuid)")
        // No mute for now - testing capture
        logMessage("[Build] Tap ready (unmuted)")
        self.tapDescription = tap

        var newTapID: AudioObjectID = 0
        logMessage("[Build] Calling AudioHardwareCreateProcessTap...")
        let tapStatus = AudioHardwareCreateProcessTap(tap, &newTapID)
        logMessage("[Build] Tap status: \(tapStatus), tapID: \(newTapID)")
        guard tapStatus == noErr else {
            throw AudioEngineError.tapCreationFailed(tapStatus)
        }
        self.tapID = newTapID
        logMessage("[Build] Tap created: \(tapID)")

        // 4. Create aggregate device with tap
        // Get output device UID for the aggregate
        let outputDeviceUID = try getDeviceUID(outputDeviceID)
        logMessage("[Build] Output device UID: \(outputDeviceUID)")

        let tapUIDString = tap.uuid.uuidString
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MacPEQ Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.macpeq.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUIDString]
            ],
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: true,
        ]
        var aggID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggID)
        guard aggStatus == noErr else {
            throw AudioEngineError.aggregateCreationFailed(aggStatus)
        }
        self.aggregateDeviceID = aggID
        logMessage("[Build] Aggregate device: \(aggregateDeviceID)")

        // 5. Read tap format
        let tapFormat = try getTapFormat(tapID: tapID)
        let isNonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        logMessage("[Build] Tap format: \(tapFormat.mSampleRate)Hz, \(tapFormat.mChannelsPerFrame)ch, \(tapFormat.mBitsPerChannel)bit, nonInterleaved=\(isNonInterleaved)")

        // 6. Initialize ring buffer (16384 frames)
        let ringBufferFrames = 16384
        let bytesPerFrame = Int(tapFormat.mBytesPerFrame)
        let channelCount = Int(tapFormat.mChannelsPerFrame)
        let isInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        // For interleaved, mBytesPerFrame already includes all channels
        // For non-interleaved, mBytesPerFrame is per-channel
        let totalBytesPerFrame = isInterleaved ? bytesPerFrame : bytesPerFrame * channelCount
        ringBuffer.initialize(capacityFrames: ringBufferFrames, bytesPerFrame: totalBytesPerFrame, channelCount: 1)
        self.tapBytesPerFrame = totalBytesPerFrame
        logMessage("[Build] bytesPerFrame=\(bytesPerFrame), totalBytesPerFrame=\(totalBytesPerFrame), interleaved=\(isInterleaved)")
        logMessage("[Build] Ring buffer initialized: \(ringBufferFrames) frames, \(channelCount)ch")

        // 7. Register IOProc on aggregate device
        // The aggregate device has tap audio as input and the output device as output.
        // IOProc copies input → output (passthrough).
        var procID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [weak self] _, inInputData, _, outOutputData, _ in
            self?.ioProcHandler(inputData: inInputData, outputData: outOutputData)
        }
        guard ioProcStatus == noErr else {
            throw AudioEngineError.ioProcFailed(ioProcStatus)
        }
        self.ioProcID = procID
        logMessage("[Build] IOProc registered")

        // Debug: query aggregate device streams
        do {
            var propSize: UInt32 = 0
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(aggregateDeviceID, &inputAddr, 0, nil, &propSize)
            let inputStreamCount = Int(propSize) / MemoryLayout<AudioStreamID>.size
            logMessage("[Build] Aggregate input streams: \(inputStreamCount)")

            var outputAddr = inputAddr
            outputAddr.mScope = kAudioObjectPropertyScopeOutput
            AudioObjectGetPropertyDataSize(aggregateDeviceID, &outputAddr, 0, nil, &propSize)
            let outputStreamCount = Int(propSize) / MemoryLayout<AudioStreamID>.size
            logMessage("[Build] Aggregate output streams: \(outputStreamCount)")
        }

        // 8. Start the aggregate device IOProc
        let startIOStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        logMessage("[Build] IOProc start status: \(startIOStatus)")
        guard startIOStatus == noErr else {
            throw AudioEngineError.startFailed(startIOStatus)
        }
        logMessage("[Build] Audio pipeline started!")

        // 10. Setup device change listener
        setupDeviceChangeListener()

        // 11. Start monitoring timer
        startMonitoring()
        logMessage("[Build] Monitoring started, timer scheduled")
    }

    // MARK: - Tap IOProc

    private func ioProcHandler(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outBuffers = UnsafeMutableAudioBufferListPointer(outputData)

        let inCount = inBuffers.count
        let outCount = outBuffers.count

        if inCount == outCount {
            // Same layout: direct copy per buffer
            for i in 0..<inCount {
                guard let inData = inBuffers[i].mData,
                      let outData = outBuffers[i].mData else { continue }
                let bytesToCopy = min(Int(inBuffers[i].mDataByteSize), Int(outBuffers[i].mDataByteSize))
                memcpy(outData, inData, bytesToCopy)
            }
        } else if inCount == 2 && outCount == 1 {
            // Non-interleaved input (2 buffers) → interleaved output (1 buffer)
            guard let inL = inBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let inR = inBuffers[1].mData?.assumingMemoryBound(to: Float.self),
                  let out = outBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let inFrames = Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let outFrames = Int(outBuffers[0].mDataByteSize) / MemoryLayout<Float>.size / 2
            let frames = min(inFrames, outFrames)
            for f in 0..<frames {
                out[f * 2]     = inL[f]
                out[f * 2 + 1] = inR[f]
            }
        } else if inCount == 1 && outCount == 2 {
            // Interleaved input (1 buffer) → non-interleaved output (2 buffers)
            guard let inp = inBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let outL = outBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = outBuffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            let inFrames = Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size / 2
            let outFrames = Int(outBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = min(inFrames, outFrames)
            for f in 0..<frames {
                outL[f] = inp[f * 2]
                outR[f] = inp[f * 2 + 1]
            }
        } else {
            // Zero output as fallback
            for i in 0..<outCount {
                if let outData = outBuffers[i].mData {
                    memset(outData, 0, Int(outBuffers[i].mDataByteSize))
                }
            }
        }

        tapCallbackCount += 1
        ioProcDebugInCount = Int32(inCount)
        ioProcDebugOutCount = Int32(outCount)
        if inCount > 0 { ioProcDebugInBytes = Int32(inBuffers[0].mDataByteSize) }
        if outCount > 0 { ioProcDebugOutBytes = Int32(outBuffers[0].mDataByteSize) }

        // Track peak level for monitoring (check both input and output)
        if inCount > 0, let data = inBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let sampleCount = Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
            var peak: Float = 0
            for s in 0..<sampleCount {
                let abs = data[s] < 0 ? -data[s] : data[s]
                if abs > peak { peak = abs }
            }
            if peak > ioProcPeakLevel { ioProcPeakLevel = peak }
        }
        // Also check output to see if our copy worked
        if outCount > 0, let data = outBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let sampleCount = Int(outBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
            var peak: Float = 0
            for s in 0..<sampleCount {
                let abs = data[s] < 0 ? -data[s] : data[s]
                if abs > peak { peak = abs }
            }
            if peak > ioProcPeakOut { ioProcPeakOut = peak }
        }
    }


    // MARK: - Tear Down

    func tearDownSync() {
        monitorTimer?.cancel()
        monitorTimer = nil

        removeDeviceChangeListener()

        if let ioProcID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }

        if tapID != 0 {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = 0
        }
        tapDescription = nil

        ringBuffer.clear()
        tapCallbackCount = 0
        renderCallbackCount = 0

        logMessage("[TearDown] Complete")
    }

    // MARK: - Device Change

    private func setupDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            logMessage("[DeviceChange] Listener fired!")
            guard let self else { return }
            self.queue.async {
                self.rebuild()
            }
        }
        self.deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        deviceListenerBlock = nil
    }

    private func rebuild() {
        // Must be called on queue
        if isRebuilding {
            pendingRebuild = true
            return
        }
        isRebuilding = true

        logMessage("[Rebuild] Starting...")
        tearDownSync()
        do {
            try buildSync()
            logMessage("[Rebuild] Success")
        } catch {
            logMessage("[Rebuild] Failed: \(error)")
        }

        isRebuilding = false
        if pendingRebuild {
            pendingRebuild = false
            rebuild()
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        logMessage("[startMonitoring] entered")
        monitorRunning = true
        func scheduleNext(_ worker: AudioEngineWorker) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                guard worker.monitorRunning else { return }
                let fillLevel = worker.ringBuffer.fillLevel()
                logMessage("[Monitor] tap=\(worker.tapCallbackCount) fill=\(Int(fillLevel * 100))pct in=\(worker.ioProcDebugInCount)x\(worker.ioProcDebugInBytes) out=\(worker.ioProcDebugOutCount)x\(worker.ioProcDebugOutBytes) peakIn=\(worker.ioProcPeakLevel) peakOut=\(worker.ioProcPeakOut)")
                worker.ioProcPeakLevel = 0
                worker.ioProcPeakOut = 0
                scheduleNext(worker)
            }
        }
        scheduleNext(self)
    }
    var monitorRunning = false

    // MARK: - Helpers

    private func getDefaultOutputDevice() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceID)
        guard status == noErr else {
            throw AudioEngineError.noOutputDevice(status)
        }
        return deviceID
    }

    private func getDeviceSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
        var sampleRate: Float64 = 0
        var propSize = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &sampleRate)
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(status)
        }
        return sampleRate
    }

    private func getTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &propSize, &format)
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(status)
        }
        return format
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var uid: CFString = "" as CFString
        var propSize = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &uid)
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(status)
        }
        return uid as String
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var propSize = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &name)
        return name as String
    }
}

// MARK: - Errors

enum AudioEngineError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case converterFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case noOutputDevice(OSStatus)
    case propertyReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s): return "Tap creation failed (OSStatus \(s)). Requires macOS 14.2+."
        case .aggregateCreationFailed(let s): return "Aggregate device failed: \(s)"
        case .converterFailed(let s): return "Audio converter failed: \(s)"
        case .ioProcFailed(let s): return "IOProc registration failed: \(s)"
        case .startFailed(let s): return "Audio start failed: \(s)"
        case .noOutputDevice(let s): return "No output device: \(s)"
        case .propertyReadFailed(let s): return "Property read failed: \(s)"
        }
    }
}
