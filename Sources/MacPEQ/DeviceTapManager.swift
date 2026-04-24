import CoreAudio
import AudioToolbox
import Foundation

/// Manages pre-muted taps on all output devices so that when the system switches
/// default device, the new device is already muted — no raw audio blip.
///
/// All internal state (`taps`) is protected by a private serial queue.
@available(macOS 14.2, *)
final class DeviceTapManager {
    private struct DeviceTap {
        let deviceID: AudioDeviceID
        let deviceUID: String
        let tapID: AudioObjectID
    }

    private let queue = DispatchQueue(label: "com.macpeq.tapmanager", qos: .userInitiated)
    private var taps: [AudioDeviceID: DeviceTap] = [:]
    private var deviceListListener: AudioObjectPropertyListenerProc?

    var activeDeviceID: AudioDeviceID = 0
    static weak var shared: DeviceTapManager?

    func start() {
        queue.sync {
            createTapsOnAllDevices()
        }
        registerDeviceListListener()
    }

    func stop() {
        unregisterDeviceListListener()
        queue.sync { [weak self] in
            guard let self = self else { return }
            for (_, tap) in self.taps { AudioHardwareDestroyProcessTap(tap.tapID) }
            self.taps.removeAll()
        }
    }

    /// Thread-safe synchronous accessor for tap ID.
    func tapID(for deviceID: AudioDeviceID) -> AudioObjectID? {
        queue.sync {
            if let existing = taps[deviceID] { return existing.tapID }
            return createTapSync(for: deviceID)
        }
    }

    func destroyTap(for deviceID: AudioDeviceID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let tap = self.taps.removeValue(forKey: deviceID) else { return }
            AudioHardwareDestroyProcessTap(tap.tapID)
        }
    }

    func handleDeviceListChange() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let devices = self.getAllOutputDevices()

            for (devID, devUID) in devices where self.taps[devID] == nil {
                self.createTapSync(for: devID, uid: devUID)
            }

            let currentDeviceIDs = Set(devices.map { $0.0 })
            for (devID, tap) in self.taps where !currentDeviceIDs.contains(devID) && devID != self.activeDeviceID {
                AudioHardwareDestroyProcessTap(tap.tapID)
                self.taps.removeValue(forKey: devID)
            }
        }
    }

    // MARK: - Private

    private func createTapsOnAllDevices() {
        let devices = getAllOutputDevices()
        for (devID, devUID) in devices { createTapSync(for: devID, uid: devUID) }
        Logger.info("Pre-muted taps created", metadata: ["count": "\(taps.count)"])
    }

    /// Must be called on `queue`.
    @discardableResult
    private func createTapSync(for deviceID: AudioDeviceID, uid: String? = nil) -> AudioObjectID? {
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
