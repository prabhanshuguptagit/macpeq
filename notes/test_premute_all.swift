#!/usr/bin/env swift
// Test: Pre-mute all devices to eliminate the "blip" on device switch
//
// Theory: The blip of raw audio on the new device happens because our muted tap
// only exists on the OLD device. The new device has no tap → audio plays raw.
//
// If we create muted taps on ALL output devices at startup, then when the system
// switches, the new device is already muted → no blip.
//
// This test:
// 1. Enumerates all output devices
// 2. Creates a muted tap on each one
// 3. Only builds the full pipeline (aggregate + IOProc + AUHAL) on the current default
// 4. On device switch: just moves the pipeline, taps already exist everywhere

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

// MARK: - Per-device tap info

struct DeviceTap {
    let deviceID: AudioDeviceID
    let deviceUID: String
    let deviceName: String
    var tapID: AudioObjectID
}

// MARK: - Engine

final class TestEngine {
    // Active pipeline (only on current default device)
    var aggregateID: AudioObjectID = 0
    var ioProcID: AudioDeviceIOProcID?
    var au: AudioUnit?
    var ringBuffer: TestRingBuffer?
    var format = AudioStreamBasicDescription()
    var currentDeviceID: AudioDeviceID = 0

    // Pre-created taps on ALL devices
    var deviceTaps: [AudioDeviceID: DeviceTap] = [:]

    // Logging
    var renderCount = 0
    var lastLogTime = Date()

    // Device change
    static weak var shared: TestEngine?
    var deviceChangeListener: AudioObjectPropertyListenerProc?
    var isRebuilding = false

    // MARK: - Helpers

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

    func getAllOutputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
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

        var result: [(id: AudioDeviceID, uid: String, name: String)] = []

        for devID in devices {
            // Check if it has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &streamSize)
            if streamSize == 0 { continue }  // No output streams

            // Get UID
            var uidCF: CFString = "" as CFString
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uidCF) { ptr in
                AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &ptr.pointee)
            }
            guard uidStatus == noErr else { continue }

            // Get name
            var nameCF: CFString = "" as CFString
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &nameCF) { ptr in
                AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, &ptr.pointee)
            }

            result.append((id: devID, uid: uidCF as String, name: nameCF as String))
        }

        return result
    }

    // MARK: - Tap creation (just the tap, no aggregate)

    func createMutedTap(for deviceID: AudioDeviceID, deviceUID: String) -> AudioObjectID? {
        guard let ownObj = getOwnProcessObject() else {
            print("  FAIL: Get own process object")
            return nil
        }

        let tapDesc = CATapDescription(
            __processes: [NSNumber(value: ownObj)],
            andDeviceUID: deviceUID,
            withStream: 0
        )
        tapDesc.isPrivate = true
        tapDesc.isExclusive = true
        tapDesc.muteBehavior = .muted

        var newTapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr else {
            return nil
        }
        return newTapID
    }

    // MARK: - Pipeline (aggregate + IOProc + AUHAL) for active device

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

    func buildPipeline(deviceID: AudioDeviceID, tapID: AudioObjectID) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        func ms() -> String { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000) }

        // Get tap format
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &format)
        print("  [+\(ms())ms] Format: \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch")

        // Create aggregate
        guard let tapUIDCF = getTapUID(tapID) else {
            print("  FAIL: Get tap UID")
            return false
        }

        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TestPreMute",
            kAudioAggregateDeviceUIDKey: "com.test.premute.\(tapID)",
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUIDCF as String, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]

        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateID) == noErr else {
            print("  FAIL: Create aggregate")
            return false
        }
        print("  [+\(ms())ms] Aggregate \(aggregateID)")

        // Ring buffer
        ringBuffer = TestRingBuffer(capacity: 32768 * Int(format.mChannelsPerFrame))

        // IOProc
        let ioProc: AudioDeviceIOProc = { _, _, inData, _, _, _, userData in
            let engine = Unmanaged<TestEngine>.fromOpaque(userData!).takeUnretainedValue()
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

        guard AudioDeviceCreateIOProcID(
            aggregateID, ioProc,
            Unmanaged.passUnretained(self).toOpaque(), &ioProcID
        ) == noErr else {
            print("  FAIL: Create IOProc")
            return false
        }
        print("  [+\(ms())ms] IOProc created")

        // AUHAL
        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &compDesc) else { return false }

        var newAU: AudioUnit?
        guard AudioComponentInstanceNew(comp, &newAU) == noErr, let auUnit = newAU else { return false }
        au = auUnit

        var dev = deviceID
        AudioUnitSetProperty(auUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                             0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        var enable: UInt32 = 1
        AudioUnitSetProperty(auUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, 4)
        enable = 0
        AudioUnitSetProperty(auUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4)

        var fmt = format
        AudioUnitSetProperty(auUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        let render: AURenderCallback = { userData, _, _, frames, _, data in
            let engine = Unmanaged<TestEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.renderCount += 1
            if engine.renderCount % 100 == 0 {
                let now = Date()
                if now.timeIntervalSince(engine.lastLogTime) > 1.0 {
                    print("[Render] #\(engine.renderCount), ring: \(engine.ringBuffer?.availableCount ?? 0)")
                    engine.lastLogTime = now
                }
            }
            let bufferList = UnsafeMutableAudioBufferListPointer(data!)
            for buffer in bufferList {
                guard let dest = buffer.mData else { continue }
                let samples = dest.assumingMemoryBound(to: Float.self)
                let totalSamples = Int(frames) * Int(buffer.mNumberChannels)
                memset(samples, 0, totalSamples * MemoryLayout<Float>.size)
                _ = engine.ringBuffer?.read(into: samples, count: totalSamples)
            }
            return noErr
        }

        var cbStruct = AURenderCallbackStruct(
            inputProc: render,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(auUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(auUnit) == noErr else {
            print("  FAIL: Init AUHAL")
            return false
        }
        print("  [+\(ms())ms] AUHAL ready for device \(deviceID)")

        // Start
        AudioDeviceStart(aggregateID, ioProcID!)
        AudioOutputUnitStart(auUnit)
        print("  [+\(ms())ms] Audio running")

        currentDeviceID = deviceID
        return true
    }

    func teardownPipeline() {
        if let auUnit = au {
            AudioOutputUnitStop(auUnit)
            AudioUnitUninitialize(auUnit)
            AudioComponentInstanceDispose(auUnit)
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
        ringBuffer = nil
    }

    // MARK: - Start

    func start() -> Bool {
        guard let defaultDevice = getDefaultOutputDevice() else {
            print("FAIL: No default output device")
            return false
        }

        // Step 1: Enumerate all output devices and create muted taps
        let devices = getAllOutputDevices()
        print("Found \(devices.count) output devices:")
        for dev in devices {
            print("  [\(dev.id)] \(dev.name) (\(dev.uid))")

            if let tapID = createMutedTap(for: dev.id, deviceUID: dev.uid) {
                deviceTaps[dev.id] = DeviceTap(
                    deviceID: dev.id, deviceUID: dev.uid, deviceName: dev.name, tapID: tapID
                )
                print("    → Muted tap \(tapID) created")
            } else {
                print("    → SKIP: Could not create tap")
            }
        }

        print("\nMuted taps on \(deviceTaps.count) devices")
        print("Default device: \(defaultDevice)")

        // Step 2: Build active pipeline on default device
        guard let tap = deviceTaps[defaultDevice] else {
            print("FAIL: No tap for default device \(defaultDevice)")
            return false
        }

        print("\nBuilding pipeline on \(tap.deviceName)...")
        guard buildPipeline(deviceID: defaultDevice, tapID: tap.tapID) else {
            return false
        }

        // Step 3: Register device change listener
        registerDeviceChangeListener()
        return true
    }

    // MARK: - Device switch

    func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            print("\n[listener] Default output device changed!")
            TestEngine.shared?.handleDeviceChange()
            return noErr
        }
        deviceChangeListener = listener
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, listener, nil
        )
    }

    func handleDeviceChange() {
        guard !isRebuilding else { return }
        isRebuilding = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self.rebuild()
            self.isRebuilding = false
        }
    }

    func rebuild() {
        let t0 = CFAbsoluteTimeGetCurrent()
        func ms() -> String { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000) }

        guard let newDeviceID = getDefaultOutputDevice() else { return }
        if newDeviceID == currentDeviceID {
            print("[rebuild] Same device, ignoring")
            return
        }

        guard let tap = deviceTaps[newDeviceID] else {
            print("[rebuild] No pre-created tap for device \(newDeviceID)!")
            return
        }

        print("[rebuild +\(ms())ms] Switching \(currentDeviceID) → \(newDeviceID) (\(tap.deviceName))")
        print("[rebuild +\(ms())ms] Tap \(tap.tapID) already exists and is MUTED on new device")

        // Teardown old pipeline (tap stays!)
        teardownPipeline()
        print("[rebuild +\(ms())ms] Old pipeline torn down")

        // Build new pipeline using pre-existing tap
        guard buildPipeline(deviceID: newDeviceID, tapID: tap.tapID) else {
            print("[rebuild] FAIL: Could not build pipeline on new device")
            return
        }
        print("[rebuild +\(ms())ms] DONE")
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
        teardownPipeline()

        // Destroy all taps
        for (_, tap) in deviceTaps {
            AudioHardwareDestroyProcessTap(tap.tapID)
            print("Destroyed tap \(tap.tapID) on \(tap.deviceName)")
        }
        deviceTaps.removeAll()
    }
}

// MARK: - Main

if #available(macOS 14.2, *) {
    print("=== Pre-Mute All Devices Test ===")
    print("Theory: muted taps on all devices at startup → no blip on switch")
    print("")

    let engine = TestEngine()
    TestEngine.shared = engine

    if engine.start() {
        print("\nAudio running. Switch devices to test.")
        print("Listen for: does the blip of raw audio on the new device disappear?")
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
