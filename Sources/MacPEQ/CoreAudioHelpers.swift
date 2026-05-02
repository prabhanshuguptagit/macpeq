import CoreAudio
import AudioToolbox
import Foundation

// MARK: - Property access

/// Read a CoreAudio property into `value`. The property's scope is global and the
/// element is `main` — the common case. For anything else, use `AudioObjectGetPropertyData` directly.
func getProperty<T>(
    of objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    value: inout T
) -> OSStatus {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
}

/// Read a CoreAudio property that requires a qualifier (e.g. translating a PID
/// to a process object).
func getProperty<T, Q>(
    of objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    qualifier: inout Q,
    value: inout T
) -> OSStatus {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(objectID, &address,
        UInt32(MemoryLayout<Q>.size), &qualifier, &size, &value)
}

// MARK: - Device helpers

/// The system's current default output device, or nil if it can't be read.
func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = 0
    guard getProperty(of: AudioObjectID(kAudioObjectSystemObject),
                      selector: kAudioHardwarePropertyDefaultOutputDevice,
                      value: &deviceID) == noErr else { return nil }
    return deviceID
}

/// Mute or unmute a device's output. Falls back to setting volume to 0/1 on
/// devices (some USB / virtual devices) that don't expose a mute property.
func setDeviceMute(_ deviceID: AudioDeviceID, muted: Bool) {
    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    if AudioObjectHasProperty(deviceID, &muteAddress) {
        var mute: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &mute)
        return
    }

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

// MARK: - ScratchBuffer

/// A fixed-capacity interleaved float buffer used as scratch space in the audio
/// render path: ring buffer → scratch → EQ → output. Owns its allocation and
/// frees it on deinit, so the engine doesn't have to track three loose fields.
final class ScratchBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let frameCapacity: Int
    let channels: Int

    var sampleCount: Int { frameCapacity * channels }

    init(frameCapacity: Int, channels: Int) {
        self.frameCapacity = frameCapacity
        self.channels = channels
        let total = frameCapacity * channels
        self.pointer = .allocate(capacity: total)
        pointer.initialize(repeating: 0, count: total)
    }

    deinit {
        pointer.deinitialize(count: sampleCount)
        pointer.deallocate()
    }
}
