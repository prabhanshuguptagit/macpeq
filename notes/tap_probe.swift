// tap_probe.swift — standalone diagnostic for global CATapDescription behavior
//
// Build + run:
//   swiftc tap_probe.swift -o tap_probe -framework CoreAudio -framework AudioToolbox -framework Foundation
//   ./tap_probe
//
// Or just:
//   swift tap_probe.swift
//
// Requires: macOS 14.4+, "System Audio Recording Only" permission (Privacy & Security
// → Screen & System Audio Recording). On first run you may need to grant permission
// to the Terminal app you're running this from.
//
// What it does:
//   1. Creates a global tap (nil deviceUID, mono mixdown, unmuted so we don't silence
//      your speakers during testing).
//   2. Wraps it in a private aggregate device.
//   3. Runs an IOProc that every ~1s logs: frame count, non-zero sample %, RMS in dBFS.
//   4. Listens for kAudioHardwarePropertyDefaultOutputDevice changes. On each change:
//        - logs old + new device name / ID / nominal rate / output channel count
//        - re-queries kAudioTapPropertyFormat on the SAME tap object
//        - logs whether the tap's reported format changed
//        - keeps running — does NOT rebuild the tap or aggregate
//   5. Runs until you Ctrl-C.
//
// What to do with it:
//   - Start it. Play audio from something (music, YouTube tab).
//   - Switch the default output device in System Settings → Sound (or the menu bar
//     sound icon) between devices with different sample rates AND channel counts.
//     E.g. MacBook speakers (2ch/48k) ↔ Behringer (12ch/44.1k).
//   - Watch the logs. Specifically look for:
//       (a) Does the tap format rate change to match the new device?
//       (b) Does the IOProc keep firing with non-zero data, or does it stall / zero out?
//       (c) Does the RMS level drop noticeably on multi-pair devices vs stereo?
//           (The forum report says ~-12 dB on 4 stereo pairs.)

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Small helpers

func log(_ msg: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000))
    FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

func getProperty<T>(_ objectID: AudioObjectID,
                    _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    into value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
}

func deviceName(_ id: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &name) { ptr in
        getProperty(id, kAudioDevicePropertyDeviceNameCFString, into: &ptr.pointee)
    }
    return status == noErr ? (name as String) : "unknown"
}

func deviceNominalRate(_ id: AudioDeviceID) -> Float64 {
    var rate: Float64 = 0
    _ = getProperty(id, kAudioDevicePropertyNominalSampleRate, into: &rate)
    return rate
}

func deviceOutputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getDefaultOutputDevice() -> AudioDeviceID {
    var id: AudioDeviceID = 0
    _ = getProperty(AudioObjectID(kAudioObjectSystemObject),
                    kAudioHardwarePropertyDefaultOutputDevice,
                    into: &id)
    return id
}

func describeASBD(_ f: AudioStreamBasicDescription) -> String {
    let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    return "rate=\(Int(f.mSampleRate)) ch=\(f.mChannelsPerFrame) " +
           "bits=\(f.mBitsPerChannel) float=\(isFloat) " +
           "nonInterleaved=\(nonInterleaved) formatID=\(f.mFormatID)"
}

// MARK: - Probe state (held in a class so callbacks can access via refcon)

final class Probe {
    var tapID: AudioObjectID = 0
    var tapUID: String = ""
    var aggID: AudioDeviceID = 0
    var ioProcID: AudioDeviceIOProcID?
    var tapFormat = AudioStreamBasicDescription()

    // IOProc stats (touched from realtime thread — use atomic-ish single writers/readers)
    var callCount: Int = 0
    var bufferCountSum: Int = 0
    var totalFrames: Int = 0
    var sumSquares: Double = 0
    var nonZeroSamples: Int = 0
    var totalSamples: Int = 0
    var lastLogTime: Date = Date()

    // Last-seen default device, for change detection
    var currentDeviceID: AudioDeviceID = 0

    func createGlobalTap() -> Bool {
        // DIAGNOSTIC: empty exclusion list to test whether own-PID exclusion
        // is what's causing all-zero samples.
        let excluded: [AudioObjectID] = []
        log("Exclusion list: empty (diagnostic mode)")

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "tap_probe"
        desc.isPrivate = true
        desc.isExclusive = true
        desc.muteBehavior = .unmuted

        var newTap: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != 0 else {
            log("AudioHardwareCreateProcessTap failed: status=\(status)")
            return false
        }
        tapID = newTap
        tapUID = desc.uuid.uuidString

        // Read tap format immediately
        var fmt = AudioStreamBasicDescription()
        let fmtStatus = getProperty(tapID, kAudioTapPropertyFormat, into: &fmt)
        if fmtStatus == noErr {
            tapFormat = fmt
            log("Tap created id=\(tapID) uuid=\(tapUID)")
            log("  initial tap format: \(describeASBD(fmt))")
        } else {
            log("Tap created id=\(tapID) but kAudioTapPropertyFormat failed: \(fmtStatus)")
        }
        return true
    }

    func createAggregate() -> Bool {
        let uid = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "tap_probe_agg",
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard status == noErr else {
            log("AudioHardwareCreateAggregateDevice failed: \(status)")
            return false
        }
        log("Aggregate created id=\(aggID)")
        return true
    }

    func setupIOProc() -> Bool {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(aggID, { _, _, inputData, _, _, _, clientData -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let probe = Unmanaged<Probe>.fromOpaque(clientData).takeUnretainedValue()
            probe.handleIOProc(inputData: inputData)
            return noErr
        }, selfPtr, &procID)

        guard status == noErr, let procID = procID else {
            log("AudioDeviceCreateIOProcID failed: \(status)")
            return false
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggID, procID)
        if startStatus != noErr {
            log("AudioDeviceStart failed: \(startStatus)")
            return false
        }
        log("IOProc started (AudioDeviceStart returned noErr)")

        // Verify IOProc is actually running
        var isRunning: UInt32 = 0
        let runStatus = getProperty(aggID, kAudioDevicePropertyDeviceIsRunning, into: &isRunning)
        log("  aggregate IsRunning: \(isRunning) (status=\(runStatus))")

        // Log aggregate's own nominal rate
        var aggRate: Float64 = 0
        _ = getProperty(aggID, kAudioDevicePropertyNominalSampleRate, into: &aggRate)
        log("  aggregate nominal rate: \(Int(aggRate))")

        // Log aggregate's output channel count
        log("  aggregate output channels: \(deviceOutputChannelCount(aggID))")

        return true
    }

    func handleIOProc(inputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        )
        callCount += 1
        bufferCountSum += abl.count

        for buffer in abl {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = sampleCount / channels
            totalFrames += frames

            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<sampleCount {
                let s = samples[i]
                if s != 0 { nonZeroSamples += 1 }
                sumSquares += Double(s) * Double(s)
            }
            totalSamples += sampleCount
        }

        // Log once per second unconditionally — do NOT gate on having seen buffers,
        // so we can distinguish "IOProc never fired" from "IOProc fired with no data".
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= 1.0 {
            let rms = totalSamples > 0 ? sqrt(sumSquares / Double(totalSamples)) : 0
            let dbfs = rms > 0 ? 20 * log10(rms) : -.infinity
            let nonZeroPct = totalSamples > 0 ? 100.0 * Double(nonZeroSamples) / Double(totalSamples) : 0
            let dbfsStr = dbfs.isFinite ? String(format: "%.1f dBFS", dbfs) : "silent"
            let avgBuffers = callCount > 0 ? Double(bufferCountSum) / Double(callCount) : 0
            log(String(format: "IOProc: %d calls, avgBuffers=%.1f, %d frames, %.0f%% non-zero, RMS=%@",
                       callCount, avgBuffers, totalFrames, nonZeroPct, dbfsStr))

            callCount = 0
            bufferCountSum = 0
            totalFrames = 0
            sumSquares = 0
            nonZeroSamples = 0
            totalSamples = 0
            lastLogTime = now
        }
    }

    func registerDeviceChangeListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            { _, _, _, clientData -> OSStatus in
                guard let clientData = clientData else { return noErr }
                let probe = Unmanaged<Probe>.fromOpaque(clientData).takeUnretainedValue()
                DispatchQueue.main.async { probe.handleDeviceChange() }
                return noErr
            },
            selfPtr
        )
        if status == noErr {
            log("Default-output-device listener registered")
        } else {
            log("Failed to register listener: \(status)")
        }
    }

    func handleDeviceChange() {
        let newID = getDefaultOutputDevice()
        guard newID != currentDeviceID else { return }

        let oldID = currentDeviceID
        currentDeviceID = newID

        log("────────────────────────────────────────────────────────")
        log("DEFAULT DEVICE CHANGED")
        log("  old: id=\(oldID) name='\(deviceName(oldID))' " +
            "rate=\(Int(deviceNominalRate(oldID))) outCh=\(deviceOutputChannelCount(oldID))")
        log("  new: id=\(newID) name='\(deviceName(newID))' " +
            "rate=\(Int(deviceNominalRate(newID))) outCh=\(deviceOutputChannelCount(newID))")

        // Re-query tap format on the SAME tap object
        var fmt = AudioStreamBasicDescription()
        let status = getProperty(tapID, kAudioTapPropertyFormat, into: &fmt)
        if status == noErr {
            let rateChanged = Int(fmt.mSampleRate) != Int(tapFormat.mSampleRate)
            let chChanged = fmt.mChannelsPerFrame != tapFormat.mChannelsPerFrame
            log("  tap format now: \(describeASBD(fmt))")
            log("  -> rate changed: \(rateChanged), channels changed: \(chChanged)")
            tapFormat = fmt
        } else {
            log("  tap format re-query FAILED: \(status)")
        }
        log("────────────────────────────────────────────────────────")
    }

    func logInitialDevice() {
        currentDeviceID = getDefaultOutputDevice()
        log("Initial default output: id=\(currentDeviceID) " +
            "name='\(deviceName(currentDeviceID))' " +
            "rate=\(Int(deviceNominalRate(currentDeviceID))) " +
            "outCh=\(deviceOutputChannelCount(currentDeviceID))")
    }

    func teardown() {
        if let procID = ioProcID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != 0 {
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        log("Teardown complete")
    }
}

// MARK: - Main

guard #available(macOS 14.4, *) else {
    log("Requires macOS 14.4+")
    exit(1)
}

let probe = Probe()

probe.logInitialDevice()
guard probe.createGlobalTap() else { exit(1) }
guard probe.createAggregate() else { probe.teardown(); exit(1) }
guard probe.setupIOProc() else { probe.teardown(); exit(1) }
probe.registerDeviceChangeListener()

log("Running. Play some audio, then switch default output devices in System Settings.")
log("Press Ctrl-C to stop.")

// Main-thread heartbeat, independent of IOProc. Lets us distinguish
// "IOProc never fires" from "process hung" from "IOProc fires with no data".
var lastSeenCallCount = 0
let heartbeat = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    let current = probe.callCount
    if current == lastSeenCallCount {
        log("[heartbeat] IOProc has fired 0 times in the last 2s (probe.callCount=\(current))")
    }
    lastSeenCallCount = current
}
RunLoop.main.add(heartbeat, forMode: .common)

// Clean shutdown on SIGINT
signal(SIGINT) { _ in
    FileHandle.standardError.write("\nInterrupted, cleaning up...\n".data(using: .utf8)!)
    exit(0)
}

// Run the main loop so the device-change listener can fire on the main queue
RunLoop.main.run()
