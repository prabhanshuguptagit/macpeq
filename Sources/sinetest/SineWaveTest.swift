import CoreAudio
import AudioToolbox
import Foundation
import AVFoundation

/// Simple test: Generate sine wave directly in AUHAL render callback
/// This tests the speaker output path independently of the tap/ring buffer
@available(macOS 14.2, *)
final class SineWaveTest {
    private var outputAU: AudioUnit?
    private var phase: Float = 0
    private let frequency: Float = 1000.0 // 1kHz tone
    private let sampleRate: Float = 48000.0
    
    func start() -> Bool {
        Logger.info("SineWaveTest: Starting 1kHz tone test")
        
        // Get default output device
        guard let defaultDevice = getDefaultOutputDevice() else {
            Logger.error("Failed to get default output device")
            return false
        }
        Logger.info("Default output device", metadata: ["id": "\(defaultDevice)"])
        
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
        var deviceID = defaultDevice
        let devStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        Logger.info("Set AUHAL device", metadata: ["status": "\(devStatus)"])
        
        // Enable output on element 0 (output bus)
        var enable: UInt32 = 1
        let enableOutStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enable,
            UInt32(MemoryLayout<UInt32>.size)
        )
        Logger.info("Enabled output", metadata: ["status": "\(enableOutStatus)"])
        
        // Disable input on element 1 (input bus)
        enable = 0
        let disableInStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enable,
            UInt32(MemoryLayout<UInt32>.size)
        )
        Logger.info("Disabled input", metadata: ["status": "\(disableInStatus)"])
        
        // Get the device's stream format and use it
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let getFmtStatus = AudioUnitGetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &format,
            &size
        )
        Logger.info("Got output format", metadata: [
            "status": "\(getFmtStatus)",
            "rate": "\(Int(format.mSampleRate))",
            "channels": "\(format.mChannelsPerFrame)",
            "float": "\(format.mFormatFlags & kAudioFormatFlagIsFloat != 0)"
        ])
        
        // Set the input format to match (this is what we write to)
        let setFmtStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        Logger.info("Set input format", metadata: ["status": "\(setFmtStatus)"])
        
        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
                guard let ioData = ioData else { return noErr }
                let test = Unmanaged<SineWaveTest>.fromOpaque(inRefCon).takeUnretainedValue()
                return test.renderSineWave(frames: inNumberFrames, buffers: ioData)
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
            Logger.error("SetRenderCallback failed", metadata: ["status": "\(cbStatus)"])
            return false
        }
        Logger.info("Render callback set")
        
        // Initialize
        let initStatus = AudioUnitInitialize(au)
        guard initStatus == noErr else {
            Logger.error("AudioUnitInitialize failed", metadata: ["status": "\(initStatus)"])
            return false
        }
        Logger.info("AUHAL initialized")
        
        // Start
        let startStatus = AudioOutputUnitStart(au)
        guard startStatus == noErr else {
            Logger.error("AudioOutputUnitStart failed", metadata: ["status": "\(startStatus)"])
            return false
        }
        Logger.info("✅ AUHAL started - you should hear a 1kHz tone now!")
        
        return true
    }
    
    func stop() {
        if let au = outputAU {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputAU = nil
        }
        Logger.info("SineWaveTest stopped")
    }
    
    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )
        guard status == noErr else { return nil }
        return deviceID
    }
    
    private func renderSineWave(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = buffers.pointee
        
        for i in 0..<Int(bufferList.mNumberBuffers) {
            let buffer = bufferList.mBuffers
            guard buffer.mData != nil else { continue }
            
            let channels = Int(buffer.mNumberChannels)
            let dest = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            for frame in 0..<Int(frames) {
                let sample = sin(phase) * 0.5 // 50% volume sine wave
                phase += 2 * Float.pi * frequency / sampleRate
                if phase > 2 * Float.pi { phase -= 2 * Float.pi }
                
                // Write to all channels
                for ch in 0..<channels {
                    dest[frame * channels + ch] = sample
                }
            }
        }
        
        return noErr
    }
}
