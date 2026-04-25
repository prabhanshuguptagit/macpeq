#!/usr/bin/env swift
// Minimal test: Tap → Simple RingBuffer → AUHAL with zero-first approach
// Tests if Core Audio tap device switch glitch is inherent or our bug

import Foundation
import CoreAudio
import AudioToolbox

// Simple array ring buffer (like original working test)
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

// Simple engine
final class TestEngine {
    var tapID: AudioObjectID = 0
    var aggregateID: AudioObjectID = 0
    var ioProcID: AudioDeviceIOProcID?
    var au: AudioUnit?
    var ringBuffer: TestRingBuffer?
    var format = AudioStreamBasicDescription()
    
    // Counters for logging
    var ioProcCount = 0
    var renderCount = 0
    var lastLogTime = Date()
    
    var currentDeviceID: AudioDeviceID = 0
    
    func start(deviceID: AudioDeviceID) -> Bool {
        currentDeviceID = deviceID
        // Create tap
        var uidCF: CFString = "" as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        _ = withUnsafeMutablePointer(to: &uidCF) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ptr.pointee)
        }
        
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var ownObj: AudioObjectID = 0
        var pid = ownPID
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidSize = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = withUnsafeMutablePointer(to: &ownObj) { objPtr in
            withUnsafeMutablePointer(to: &pid) { pidPtr in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &pidAddr, UInt32(MemoryLayout<Int32>.size), pidPtr, &pidSize, objPtr)
            }
        }
        
        let tapDesc = CATapDescription(__processes: [NSNumber(value: ownObj)], andDeviceUID: uidCF as String, withStream: 0)
        tapDesc.isPrivate = true
        tapDesc.isExclusive = true
        tapDesc.muteBehavior = .muted
        
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr else {
            print("FAIL: Create tap")
            return false
        }
        print("OK: Tap created \(tapID)")
        
        // Get format
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &format)
        print("OK: Format \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch")
        
        // Create ring buffer (recreated each start like MacPEQ)
        ringBuffer = TestRingBuffer(capacity: 32768 * Int(format.mChannelsPerFrame))
        
        // Create aggregate
        var tapUIDCF: CFString = "" as CFString
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        _ = withUnsafeMutablePointer(to: &tapUIDCF) { ptr in
            AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &ptr.pointee)
        }
        
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TestTap",
            kAudioAggregateDeviceUIDKey: "com.test.tap.\(tapID)",
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUIDCF as String, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateID) == noErr else {
            print("FAIL: Create aggregate")
            return false
        }
        print("OK: Aggregate \(aggregateID)")
        
        // Create IOProc with logging
        let ioProc: AudioDeviceIOProc = { _, _, inData, _, _, _, userData in
            let engine = Unmanaged<TestEngine>.fromOpaque(userData!).takeUnretainedValue()
            engine.ioProcCount += 1
            
            // Log every 100 IOProc calls (~100ms at 48kHz/512 frames)
            if engine.ioProcCount % 100 == 0 {
                let now = Date()
                if now.timeIntervalSince(engine.lastLogTime) > 1.0 {
                    print("[IOProc] received \(engine.ioProcCount) callbacks")
                    engine.lastLogTime = now
                }
            }
            
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer<AudioBufferList>(mutating: inData))
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let frames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * 4)
                _ = engine.ringBuffer?.write(samples, count: frames * Int(buffer.mNumberChannels))
            }
            return noErr
        }
        
        guard AudioDeviceCreateIOProcID(aggregateID, ioProc, Unmanaged.passUnretained(self).toOpaque(), &ioProcID) == noErr else {
            print("FAIL: Create IOProc")
            return false
        }
        print("OK: IOProc created")
        
        // Create AUHAL
        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &compDesc) else {
            print("FAIL: Find AUHAL component")
            return false
        }
        
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au = au else {
            print("FAIL: Create AUHAL instance")
            return false
        }
        
        var dev = deviceID
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        
        var enable: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, 4)
        enable = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4)
        
        var fmt = format
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
        // MacPEQ-style render callback with logging
        let render: AURenderCallback = { userData, _, _, frames, _, data in
            let engine = Unmanaged<TestEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.renderCount += 1
            
            // Log every 100 render calls (~100ms at 48kHz)
            if engine.renderCount % 100 == 0 {
                let now = Date()
                if now.timeIntervalSince(engine.lastLogTime) > 1.0 {
                    let ringAvail = engine.ringBuffer?.availableCount ?? 0
                    
                    // Check what device we're actually outputting to
                    var currentDev: AudioDeviceID = 0
                    var devAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &devSize, &currentDev)
                    
                    print("[Render] callback #\(engine.renderCount), ring: \(ringAvail), startedDev: \(engine.currentDeviceID), currentSysDev: \(currentDev)")
                    engine.lastLogTime = now
                }
            }
            
            let bufferList = UnsafeMutableAudioBufferListPointer(data!)
            for buffer in bufferList {
                guard let dest = buffer.mData else { continue }
                let samples = dest.assumingMemoryBound(to: Float.self)
                let channelCount = Int(buffer.mNumberChannels)
                let totalSamples = Int(frames) * channelCount
                
                // MACPEQ-STYLE: Zero entire buffer first
                memset(samples, 0, totalSamples * MemoryLayout<Float>.size)
                
                // Then read from ring buffer (overwrites zeros with data)
                _ = engine.ringBuffer?.read(into: samples, count: Int(frames) * channelCount)
            }
            return noErr
        }
        
        var cbStruct = AURenderCallbackStruct(inputProc: render, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        
        guard AudioUnitInitialize(au) == noErr else {
            print("FAIL: Initialize AUHAL")
            return false
        }
        print("OK: AUHAL initialized")
        
        // Start
        AudioDeviceStart(aggregateID, ioProcID!)
        AudioOutputUnitStart(au)
        print("OK: Started")
        return true
    }
    
    func stop() {
        if let au = au {
            AudioOutputUnitStop(au)
        }
        if let ioProc = ioProcID {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        ringBuffer = nil
    }
}

// Main test
if #available(macOS 14.2, *) {
    print("=== Core Audio Tap Device Switch Test (MacPEQ style) ===")
    print("Uses: array ring buffer, recreated each start, zero-first render")
    print("")
    
    // Get default device
    var deviceID: AudioDeviceID = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    
    print("Starting with device \(deviceID)...")
    let engine = TestEngine()
    
    if engine.start(deviceID: deviceID) {
        print("\nAudio running. Switch devices in System Settings.")
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
