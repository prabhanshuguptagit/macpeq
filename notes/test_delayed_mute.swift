#!/usr/bin/env swift
// Test: Delayed tap mute during device switch
//
// Theory: The glitch on device switch is:
//   1) Blip of old audio — system briefly routes unmuted audio to new device
//   2) Silence — new tap mutes system audio but ring buffer is empty, AUHAL has nothing
//   3) Audio resumes — ring buffer fills, normal flow
//
// Fix: Create new tap as UNMUTED first, let system audio keep playing while we
// build the pipeline and fill the ring buffer. Once AUHAL is producing output,
// destroy the unmuted tap and recreate as muted. This closes the silence gap.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Ring Buffer

final class TestRingBuffer {
    private var buffer: [Float] = []
    private let capacity: Int
    private var writeIdx = 0
    private var readIdx = 0
    private var _available = 0

    init(capacity: Int) {
        self.capacity = capacity
        buffer = Array(repeating: 0, count: capacity)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        var written = 0
        for i in 0..<count {
            if _available < capacity {
                buffer[(writeIdx + i) % capacity] = samples[i]
                written += 1
            }
        }
        writeIdx = (writeIdx + written) % capacity
        _available += written
        return written
    }

    func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let toRead = min(count, _available)
        for i in 0..<toRead {
            dest[i] = buffer[(readIdx + i) % capacity]
        }
        readIdx = (readIdx + toRead) % capacity
        _available -= toRead
        return toRead
    }

    func clear() {
        readIdx = 0
        writeIdx = 0
        _available = 0
    }

    var availableCount: Int { return _available }
}

// MARK: - Engine

final class TestEngine {
    var tapID: AudioObjectID = 0
    var aggregateID: AudioObjectID = 0
    var ioProcID: AudioDeviceIOProcID?
    var au: AudioUnit?
    var ringBuffer: TestRingBuffer?
    var format = AudioStreamBasicDescription()

    var ioProcCount = 0
    var renderCount = 0
    var lastLogTime = Date()
    var currentDeviceID: AudioDeviceID = 0

    // For device change listener
    static weak var shared: TestEngine?
    var deviceChangeListener: AudioObjectPropertyListenerProc?
    var isRebuilding = false

    // MARK: - Helpers

    func getDeviceUID(_ deviceID: AudioDeviceID) -> CFString? {
        var uidCF: CFString = "" as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ptr.pointee)
        }
        return status == noErr ? uidCF : nil
    }

    func getOwnProcessObject() -> AudioObjectID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var ownObj: AudioObjectID = 0
        var pid = ownPID
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &ownObj) { objPtr in
            withUnsafeMutablePointer(to: &pid) { pidPtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &pidAddr,
                    UInt32(MemoryLayout<Int32>.size), pidPtr, &pidSize, objPtr
                )
            }
        }
        return status == noErr ? ownObj : nil
    }

    func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    // MARK: - Tap creation (parameterized mute behavior)

    func createTap(for deviceID: AudioDeviceID, muted: Bool) -> (tapID: AudioObjectID, format: AudioStreamBasicDescription)? {
        guard let uidCF = getDeviceUID(deviceID) else {
            print("  FAIL: Get device UID")
            return nil
        }

        guard let ownObj = getOwnProcessObject() else {
            print("  FAIL: Get own process object")
            return nil
        }

        let tapDesc = CATapDescription(
            __processes: [NSNumber(value: ownObj)],
            andDeviceUID: uidCF as String,
            withStream: 0
        )
        tapDesc.isPrivate = true
        tapDesc.isExclusive = true
        tapDesc.muteBehavior = muted ? .muted : .unmuted

        var newTapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr else {
            print("  FAIL: Create tap (muted=\(muted))")
            return nil
        }

        var fmt = AudioStreamBasicDescription()
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(newTapID, &fmtAddr, 0, nil, &fmtSize, &fmt)

        print("  OK: Tap \(newTapID) created (muted=\(muted)) \(Int(fmt.mSampleRate))Hz \(fmt.mChannelsPerFrame)ch")
        return (newTapID, fmt)
    }

    func getTapUID(_ tapID: AudioObjectID) -> CFString? {
        var tapUIDCF: CFString = "" as CFString
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &tapUIDCF) { ptr in
            AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &ptr.pointee)
        }
        return status == noErr ? tapUIDCF : nil
    }

    // MARK: - Aggregate + IOProc + AUHAL (reusable)

    func createAggregate(tapID: AudioObjectID) -> AudioObjectID? {
        guard let tapUIDCF = getTapUID(tapID) else {
            print("  FAIL: Get tap UID")
            return nil
        }

        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TestDelayedMute",
            kAudioAggregateDeviceUIDKey: "com.test.delayedmute.\(tapID)",
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUIDCF as String, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]

        var aggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID) == noErr else {
            print("  FAIL: Create aggregate")
            return nil
        }
        print("  OK: Aggregate \(aggID)")
        return aggID
    }

    func createIOProc(aggregateID: AudioObjectID) -> AudioDeviceIOProcID? {
        let ioProc: AudioDeviceIOProc = { _, _, inData, _, _, _, userData in
            let engine = Unmanaged<TestEngine>.fromOpaque(userData!).takeUnretainedValue()
            engine.ioProcCount += 1

            let bufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer<AudioBufferList>(mutating: inData)
            )
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let frames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * 4)
                _ = engine.ringBuffer?.write(samples, count: frames * Int(buffer.mNumberChannels))
            }
            return noErr
        }

        var procID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(
            aggregateID, ioProc,
            Unmanaged.passUnretained(self).toOpaque(), &procID
        ) == noErr else {
            print("  FAIL: Create IOProc")
            return nil
        }
        print("  OK: IOProc created")
        return procID
    }

    func createAUHAL(deviceID: AudioDeviceID, format: AudioStreamBasicDescription) -> AudioUnit? {
        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &compDesc) else {
            print("  FAIL: Find AUHAL component")
            return nil
        }

        var newAU: AudioUnit?
        guard AudioComponentInstanceNew(comp, &newAU) == noErr, let au = newAU else {
            print("  FAIL: Create AUHAL instance")
            return nil
        }

        var dev = deviceID
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                             0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

        var enable: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, 4)
        enable = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4)

        var fmt = format
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        let render: AURenderCallback = { userData, _, _, frames, _, data in
            let engine = Unmanaged<TestEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.renderCount += 1

            if engine.renderCount % 100 == 0 {
                let now = Date()
                if now.timeIntervalSince(engine.lastLogTime) > 1.0 {
                    let ringAvail = engine.ringBuffer?.availableCount ?? 0
                    print("[Render] #\(engine.renderCount), ring: \(ringAvail), dev: \(engine.currentDeviceID)")
                    engine.lastLogTime = now
                }
            }

            let bufferList = UnsafeMutableAudioBufferListPointer(data!)
            for buffer in bufferList {
                guard let dest = buffer.mData else { continue }
                let samples = dest.assumingMemoryBound(to: Float.self)
                let channelCount = Int(buffer.mNumberChannels)
                let totalSamples = Int(frames) * channelCount
                memset(samples, 0, totalSamples * MemoryLayout<Float>.size)
                _ = engine.ringBuffer?.read(into: samples, count: totalSamples)
            }
            return noErr
        }

        var cbStruct = AURenderCallbackStruct(
            inputProc: render,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(au) == noErr else {
            print("  FAIL: Initialize AUHAL")
            AudioComponentInstanceDispose(au)
            return nil
        }
        print("  OK: AUHAL initialized for device \(deviceID)")
        return au
    }

    // MARK: - Initial start (normal muted tap)

    func start(deviceID: AudioDeviceID) -> Bool {
        currentDeviceID = deviceID
        print("--- Starting on device \(deviceID) ---")

        guard let result = createTap(for: deviceID, muted: true) else { return false }
        tapID = result.tapID
        format = result.format

        ringBuffer = TestRingBuffer(capacity: 32768 * Int(format.mChannelsPerFrame))

        guard let aggID = createAggregate(tapID: tapID) else { return false }
        aggregateID = aggID

        guard let procID = createIOProc(aggregateID: aggregateID) else { return false }
        ioProcID = procID

        guard let newAU = createAUHAL(deviceID: deviceID, format: format) else { return false }
        au = newAU

        AudioDeviceStart(aggregateID, ioProcID!)
        AudioOutputUnitStart(au!)
        print("  OK: Audio running\n")

        // Register device change listener
        registerDeviceChangeListener()
        return true
    }

    // MARK: - Device change: delayed mute rebuild

    func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            TestEngine.shared?.handleDeviceChange()
            return noErr
        }
        deviceChangeListener = listener

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, listener, nil
        )
        print("  OK: Device change listener registered")
    }

    func handleDeviceChange() {
        // Coalesce — Core Audio may fire this multiple times
        guard !isRebuilding else {
            print("[DeviceChange] Already rebuilding, skipping")
            return
        }
        isRebuilding = true

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self.rebuildWithDelayedMute()
            self.isRebuilding = false
        }
    }

    /// The key idea:
    ///
    /// 1. Tear down old pipeline (AUHAL, IOProc, aggregate, tap)
    /// 2. Create NEW tap as **unmuted** — system audio keeps playing on new device
    /// 3. Build full pipeline (aggregate, IOProc, ring buffer, AUHAL)
    /// 4. Start IOProc to fill ring buffer
    /// 5. Wait for ring buffer to have enough data (~10ms worth)
    /// 6. Start AUHAL — now outputting real audio immediately
    /// 7. Destroy the unmuted tap
    /// 8. Create a **muted** tap and hot-swap the aggregate's tap list
    ///    (or: destroy aggregate + recreate with muted tap — simpler, brief overlap)
    ///
    /// The user hears: system audio (unmuted) → our processed audio (AUHAL starts)
    /// with no silence gap in between.
    func rebuildWithDelayedMute() {
        guard let newDeviceID = getDefaultOutputDevice() else {
            print("[Rebuild] FAIL: Can't get new default device")
            return
        }

        if newDeviceID == currentDeviceID {
            print("[Rebuild] Same device \(newDeviceID), ignoring")
            return
        }

        print("\n=== REBUILD: device \(currentDeviceID) → \(newDeviceID) ===")
        let rebuildStart = Date()

        // --- Step 1: Tear down old pipeline ---
        print("[Step 1] Tearing down old pipeline")
        if let oldAU = au {
            AudioOutputUnitStop(oldAU)
            AudioUnitUninitialize(oldAU)
            AudioComponentInstanceDispose(oldAU)
            au = nil
        }
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        // --- Step 2: Create UNMUTED tap on new device ---
        // System audio keeps playing naturally on the new device
        print("[Step 2] Creating UNMUTED tap on new device")
        guard let unmutedResult = createTap(for: newDeviceID, muted: false) else {
            print("[Rebuild] FAIL: Can't create unmuted tap")
            return
        }
        let unmutedTapID = unmutedResult.tapID
        format = unmutedResult.format

        // --- Step 3: Build pipeline with unmuted tap ---
        print("[Step 3] Building pipeline")
        ringBuffer = TestRingBuffer(capacity: 32768 * Int(format.mChannelsPerFrame))

        guard let aggID = createAggregate(tapID: unmutedTapID) else {
            AudioHardwareDestroyProcessTap(unmutedTapID)
            return
        }

        guard let procID = createIOProc(aggregateID: aggID) else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(unmutedTapID)
            return
        }

        guard let newAU = createAUHAL(deviceID: newDeviceID, format: format) else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(unmutedTapID)
            return
        }

        // --- Step 4: Start IOProc to fill ring buffer ---
        print("[Step 4] Starting IOProc to pre-fill ring buffer")
        AudioDeviceStart(aggID, procID)

        // Wait for ring buffer to accumulate ~10ms of audio
        // At 48kHz stereo, 10ms = 480 frames * 2ch = 960 samples
        let targetSamples = Int(format.mSampleRate * Double(format.mChannelsPerFrame)) / 100  // ~10ms
        let waitStart = Date()
        var waitLoops = 0
        while (ringBuffer?.availableCount ?? 0) < targetSamples {
            usleep(1000)  // 1ms
            waitLoops += 1
            if waitLoops > 50 {  // 50ms timeout
                print("  WARNING: Ring buffer pre-fill timeout (\(ringBuffer?.availableCount ?? 0)/\(targetSamples) samples)")
                break
            }
        }
        let prefillTime = Date().timeIntervalSince(waitStart) * 1000
        print("  OK: Ring buffer pre-filled to \(ringBuffer?.availableCount ?? 0) samples in \(String(format: "%.1f", prefillTime))ms")

        // --- Step 5: Start AUHAL — real audio from frame 1 ---
        print("[Step 5] Starting AUHAL")
        AudioOutputUnitStart(newAU)

        // At this point: system audio plays unmuted AND our AUHAL plays.
        // Brief moment of doubled audio, but it's a much smaller glitch than silence.

        // --- Step 6: Swap to muted tap ---
        // Destroy the unmuted tap + aggregate, recreate with muted tap.
        // The AUHAL keeps running and pulling from ring buffer during this swap.
        print("[Step 6] Swapping to MUTED tap")

        // Stop IOProc on unmuted aggregate
        AudioDeviceStop(aggID, procID)
        AudioDeviceDestroyIOProcID(aggID, procID)
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(unmutedTapID)

        // Create muted tap
        guard let mutedResult = createTap(for: newDeviceID, muted: true) else {
            print("[Rebuild] FAIL: Can't create muted tap — audio may be doubled!")
            // AUHAL is still running, store what we have
            self.tapID = 0
            self.aggregateID = 0
            self.ioProcID = nil
            self.au = newAU
            self.currentDeviceID = newDeviceID
            return
        }
        tapID = mutedResult.tapID

        // Recreate aggregate + IOProc with muted tap
        guard let mutedAggID = createAggregate(tapID: tapID) else {
            print("[Rebuild] FAIL: Can't create muted aggregate")
            self.aggregateID = 0
            self.ioProcID = nil
            self.au = newAU
            self.currentDeviceID = newDeviceID
            return
        }
        aggregateID = mutedAggID

        guard let mutedProcID = createIOProc(aggregateID: aggregateID) else {
            print("[Rebuild] FAIL: Can't create muted IOProc")
            self.ioProcID = nil
            self.au = newAU
            self.currentDeviceID = newDeviceID
            return
        }
        ioProcID = mutedProcID

        // Start IOProc on muted aggregate — ring buffer continues to be fed
        AudioDeviceStart(aggregateID, ioProcID!)

        // Done
        au = newAU
        currentDeviceID = newDeviceID

        let totalTime = Date().timeIntervalSince(rebuildStart) * 1000
        print("[Rebuild] Complete in \(String(format: "%.1f", totalTime))ms")
        print("  Ring buffer: \(ringBuffer?.availableCount ?? 0) samples")
        print("  AUHAL running on device \(newDeviceID)\n")
    }

    // MARK: - Stop

    func stop() {
        if let listener = deviceChangeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &address, listener, nil
            )
        }
        if let au = au {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ringBuffer = nil
    }
}

// MARK: - Main

if #available(macOS 14.2, *) {
    print("=== Delayed Tap Mute Device Switch Test ===")
    print("Strategy: unmuted tap → build pipeline → pre-fill ring → start AUHAL → swap to muted tap")
    print("Expected: no silence gap on device switch (brief doubled audio instead)")
    print("")

    guard let deviceID = {
        var id: AudioDeviceID = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return s == noErr ? id : nil
    }() else {
        print("FAIL: Can't get default output device")
        exit(1)
    }

    let engine = TestEngine()
    TestEngine.shared = engine

    if engine.start(deviceID: deviceID) {
        print("Audio running. Switch devices in System Settings to test.")
        print("Press Enter to stop...")
        _ = readLine()
        engine.stop()
        print("Stopped.")
    } else {
        print("Failed to start")
    }
} else {
    print("Requires macOS 14.2+")
}