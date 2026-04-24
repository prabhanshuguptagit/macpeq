import CoreAudio
import AudioToolbox
import Foundation

/// Creates and destroys Core Audio process taps on demand.
@available(macOS 14.2, *)
final class DeviceTapManager {
    static weak var shared: DeviceTapManager?

    /// Create a tap for the given device. Returns the tapID, or nil on failure.
    func createTap(for deviceID: AudioDeviceID) -> AudioObjectID? {
        var uidCF: CFString = "" as CFString
        guard withUnsafeMutablePointer(to: &uidCF, { ptr in
            getProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
        }) == noErr else { return nil }
        let deviceUID = uidCF as String

        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let ownProcessObject = translatePIDToProcessObject(ownPID) else { return nil }

        let tapDesc = CATapDescription(
            __processes: [NSNumber(value: ownProcessObject)],
            andDeviceUID: deviceUID,
            withStream: 0)
        tapDesc.isPrivate = true
        tapDesc.name = "MacPEQ"
        tapDesc.isExclusive = true
        tapDesc.muteBehavior = .muted

        var newTapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr else { return nil }

        Logger.info("Tap created", metadata: ["deviceUID": deviceUID, "tapID": "\(newTapID)"])
        return newTapID
    }

    /// Destroy a tap by ID.
    func destroyTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
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

    private func translatePIDToProcessObject(_ pid: Int32) -> AudioObjectID? {
        var processObject: AudioObjectID = 0
        var mutablePid = pid
        guard getProperty(of: AudioObjectID(kAudioObjectSystemObject),
                          selector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                          qualifier: &mutablePid, value: &processObject) == noErr,
              processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }
}
