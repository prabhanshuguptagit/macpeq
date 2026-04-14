import CoreAudio
import AudioToolbox
import Foundation

/// Manages pre-muted taps on all output devices so that when the system switches
/// default device, the new device is already muted — no raw audio blip.
@available(macOS 14.2, *)
final class DeviceTapManager {
    private struct DeviceTap {
        let deviceID: AudioDeviceID
        let deviceUID: String
        let tapID: AudioObjectID
    }

    private var taps: [AudioDeviceID: DeviceTap] = [:]
    private var deviceListListener: AudioObjectPropertyListenerProc?

    var activeDeviceID: AudioDeviceID = 0
    static weak var shared: DeviceTapManager?

    func start() {
        createTapsOnAllDevices()
        registerDeviceListListener()
    }

    func stop() {
        unregisterDeviceListListener()
        for (_, tap) in taps { AudioHardwareDestroyProcessTap(tap.tapID) }
        taps.removeAll()
    }

    func tapID(for deviceID: AudioDeviceID) -> AudioObjectID? {
        if let existing = taps[deviceID] { return existing.tapID }
        return createTap(for: deviceID)
    }

    func destroyTap(for deviceID: AudioDeviceID) {
        guard let tap = taps.removeValue(forKey: deviceID) else { return }
        AudioHardwareDestroyProcessTap(tap.tapID)
    }

    func handleDeviceListChange() {
        let devices = getAllOutputDevices()

        for (devID, devUID) in devices where taps[devID] == nil {
            createTap(for: devID, uid: devUID)
        }

        let currentDeviceIDs = Set(devices.map { $0.0 })
        for (devID, tap) in taps where !currentDeviceIDs.contains(devID) && devID != activeDeviceID {
            AudioHardwareDestroyProcessTap(tap.tapID)
            taps.removeValue(forKey: devID)
        }
    }

    private func createTapsOnAllDevices() {
        let devices = getAllOutputDevices()
        for (devID, devUID) in devices { createTap(for: devID, uid: devUID) }
        Logger.info("Pre-muted taps created", metadata: ["count": "\(taps.count)"])
    }

    @discardableResult
    private func createTap(for deviceID: AudioDeviceID, uid: String? = nil) -> AudioObjectID? {
        if taps[deviceID] != nil { return taps[deviceID]!.tapID }

        let deviceUID: String
        if let uid = uid {
            deviceUID = uid
        } else {
            var uidCF: CFString = "" as CFString
            guard withUnsafeMutablePointer(to: &uidCF, { ptr in
                getProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
            }) == noErr else { return nil }
            deviceUID = uidCF as String
        }

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

        taps[deviceID] = DeviceTap(deviceID: deviceID, deviceUID: deviceUID, tapID: newTapID)
        Logger.info("Tap created", metadata: ["deviceUID": deviceUID, "tapID": "\(newTapID)"])
        return newTapID
    }

    private func getAllOutputDevices() -> [(AudioDeviceID, String)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)

        var result: [(AudioDeviceID, String)] = []
        for devID in devices {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &streamSize)
            guard streamSize > 0 else { continue }

            var uidCF: CFString = "" as CFString
            guard withUnsafeMutablePointer(to: &uidCF, { ptr in
                getProperty(of: devID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
            }) == noErr else { continue }
            result.append((devID, uidCF as String))
        }
        return result
    }

    private func registerDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            DispatchQueue.main.async { DeviceTapManager.shared?.handleDeviceListChange() }
            return noErr
        }
        deviceListListener = listener
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, listener, nil)
    }

    private func unregisterDeviceListListener() {
        guard let listener = deviceListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, listener, nil)
        deviceListListener = nil
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

    deinit {
        unregisterDeviceListListener()
        for (_, tap) in taps { AudioHardwareDestroyProcessTap(tap.tapID) }
        taps.removeAll()
        DeviceTapManager.shared = nil
    }
}
