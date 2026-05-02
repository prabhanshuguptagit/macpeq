import CoreAudio
import AudioToolbox
import Foundation

/// Creates and destroys Core Audio process taps on demand. A tap captures
/// audio from a specific output device's stream.
@available(macOS 14.2, *)
final class DeviceTapManager {

    /// Create a tap for the given device. Returns the tapID, or nil on failure.
    func createTap(for deviceID: AudioDeviceID) -> AudioObjectID? {
        var uidCF: CFString = "" as CFString
        guard getProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID, value: &uidCF) == noErr else {
            return nil
        }
        let deviceUID = uidCF as String

        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let ownProcessObject = translatePIDToProcessObject(ownPID) else { return nil }
        
        let tapDesc = CATapDescription(
            __processes: [NSNumber(value: ownProcessObject)],
            andDeviceUID: deviceUID,
            withStream: 0)
        tapDesc.isPrivate = true
        tapDesc.name = "MacPEQ"
        // Exclude our own process from the tap.
        tapDesc.isExclusive = true
        tapDesc.muteBehavior = .muted

        var newTapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr else { return nil }

        Logger.info("Tap created", metadata: ["deviceUID": deviceUID, "tapID": "\(newTapID)"])
        return newTapID
    }

    func destroyTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }

    /// CoreAudio identifies processes by an opaque `AudioObjectID` rather than
    /// a PID. Translate one to the other so we can reference our own process
    /// in the tap description.
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
