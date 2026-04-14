import CoreAudio
import AudioToolbox
import Foundation

/// Manages pre-muted taps on all output devices.
///
/// Muted taps are created on every output device at startup so that when the
/// system switches default device, the new device is already muted — eliminating
/// the "blip" of raw (un-EQ'd) audio that would otherwise play before the
/// pipeline rebuilds.
///
/// Also watches for hot-plugged devices and creates pre-muted taps on them
/// immediately, so they're ready if they become the default output.
///
/// All methods must be called on the main thread (AudioEngine ensures this).
@available(macOS 14.2, *)
final class DeviceTapManager {
    private struct DeviceTap {
        let deviceID: AudioDeviceID
        let deviceUID: String
        let tapID: AudioObjectID
    }

    private var taps: [AudioDeviceID: DeviceTap] = [:]
    private var deviceListListener: AudioObjectPropertyListenerProc?

    // MARK: - Lifecycle

    init() {}

    /// Create muted taps on all current output devices + watch for hot-plug.
    func start() {
        assertMain()
        createTapsOnAllDevices()
        registerDeviceListListener()
    }

    /// Destroy all taps + stop watching for device changes.
    func stop() {
        assertMain()
        unregisterDeviceListListener()
        for (_, tap) in taps {
            AudioHardwareDestroyProcessTap(tap.tapID)
        }
        taps.removeAll()
    }

    // MARK: - Tap Access

    /// Get the tap ID for a device, creating one if needed.
    /// Returns nil only if tap creation fails.
    func tapID(for deviceID: AudioDeviceID) -> AudioObjectID? {
        assertMain()
        if let existing = taps[deviceID] {
            return existing.tapID
        }
        return createTap(for: deviceID)
    }

    /// Destroy the tap for a specific device.
    /// Used before recreating for sample rate changes on the same device.
    func destroyTap(for deviceID: AudioDeviceID) {
        assertMain()
        guard let tap = taps.removeValue(forKey: deviceID) else { return }
        AudioHardwareDestroyProcessTap(tap.tapID)
        Logger.info("Destroyed tap for device", metadata: [
            "deviceID": "\(deviceID)",
            "tapID": "\(tap.tapID)"
        ])
    }

    // MARK: - Public (called by AudioEngine on main thread)

    /// The device whose tap is currently in use by the pipeline.
    /// Used to avoid destroying the active tap during hot-unplug cleanup.
    var activeDeviceID: AudioDeviceID = 0

    /// Shared instance for C callback routing.
    static weak var shared: DeviceTapManager?

    /// Called from AudioEngine on main thread when the device list changes.
    func handleDeviceListChange() {
        assertMain()
        let devices = getAllOutputDevices()

        // Create taps on any new devices
        for (devID, devUID) in devices {
            if taps[devID] == nil {
                createTap(for: devID, uid: devUID)
            }
        }

        // Clean up taps for removed devices (but not the active one)
        let currentDeviceIDs = Set(devices.map { $0.0 })
        for (devID, tap) in taps {
            if !currentDeviceIDs.contains(devID) && devID != activeDeviceID {
                AudioHardwareDestroyProcessTap(tap.tapID)
                taps.removeValue(forKey: devID)
                Logger.info("Removed tap for disconnected device", metadata: [
                    "deviceID": "\(devID)"
                ])
            }
        }
    }

    // MARK: - Private - Tap Creation

    /// Enumerate all output devices and create a muted tap on each.
    private func createTapsOnAllDevices() {
        let devices = getAllOutputDevices()
        Logger.info("Found \(devices.count) output devices for pre-mute")

        for (devID, devUID) in devices {
            createTap(for: devID, uid: devUID)
        }

        Logger.info("Pre-muted taps created", metadata: ["count": "\(taps.count)"])
    }

    /// Create a muted tap on a single device and store it.
    @discardableResult
    private func createTap(for deviceID: AudioDeviceID, uid: String? = nil) -> AudioObjectID? {
        // Skip if we already have a tap for this device
        if taps[deviceID] != nil { return taps[deviceID]!.tapID }

        // Get UID if not provided
        let deviceUID: String
        if let uid = uid {
            deviceUID = uid
        } else {
            var uidCF: CFString = "" as CFString
            let status = withUnsafeMutablePointer(to: &uidCF) { ptr in
                getProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
            }
            guard status == noErr else { return nil }
            deviceUID = uidCF as String
        }

        // Exclude MacPEQ's own process from the tap
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownProcessObject = translatePIDToProcessObject(ownPID)
        let excludedProcesses: [NSNumber] = ownProcessObject.map { [NSNumber(value: $0)] } ?? []

        let tapDesc = CATapDescription(
            __processes: excludedProcesses,
            andDeviceUID: deviceUID,
            withStream: 0
        )
        tapDesc.isPrivate = true
        tapDesc.name = "MacPEQ"
        tapDesc.isExclusive = true

        let canMute = ownProcessObject != nil
        tapDesc.muteBehavior = canMute ? .muted : .unmuted

        var newTapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr else {
            Logger.warning("Could not create tap for device", metadata: [
                "deviceUID": deviceUID,
                "status": "\(status)"
            ])
            return nil
        }

        taps[deviceID] = DeviceTap(
            deviceID: deviceID, deviceUID: deviceUID, tapID: newTapID
        )
        Logger.info("Pre-muted tap created", metadata: [
            "deviceID": "\(deviceID)",
            "deviceUID": deviceUID,
            "tapID": "\(newTapID)"
        ])
        return newTapID
    }

    // MARK: - Private - Device Enumeration

    /// Get all output devices as (deviceID, deviceUID) pairs.
    private func getAllOutputDevices() -> [(AudioDeviceID, String)] {
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

        var result: [(AudioDeviceID, String)] = []
        for devID in devices {
            // Check if device has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &streamSize)
            if streamSize == 0 { continue }

            // Get UID
            var uidCF: CFString = "" as CFString
            let uidStatus = withUnsafeMutablePointer(to: &uidCF) { ptr in
                getProperty(of: devID, selector: kAudioDevicePropertyDeviceUID, value: &ptr.pointee)
            }
            guard uidStatus == noErr else { continue }

            result.append((devID, uidCF as String))
        }
        return result
    }

    // MARK: - Private - Device List Listener (Hot-Plug)

    /// Listen for device list changes (hot-plug) and create taps on new devices.
    /// The C callback dispatches to main; AudioEngine calls handleDeviceListChange().
    private func registerDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
            // Dispatch to main — the callback fires on a CoreAudio thread.
            // AudioEngine.handleDeviceListChangeFromTapManager() routes to
            // tapManager.handleDeviceListChange() on main.
            DispatchQueue.main.async {
                DeviceTapManager.shared?.handleDeviceListChange()
            }
            return noErr
        }
        deviceListListener = listener

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listener,
            nil
        )
        if status == noErr {
            Logger.info("Registered device list change listener")
        }
    }

    private func unregisterDeviceListListener() {
        guard let listener = deviceListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, listener, nil
        )
        deviceListListener = nil
    }

    // MARK: - Private - CoreAudio Helpers

    private func getProperty<T>(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        value: inout T
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    }

    private func getProperty<T, Q>(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        qualifier: inout Q,
        value: inout T
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(
            objectID, &address,
            UInt32(MemoryLayout<Q>.size), &qualifier,
            &size, &value
        )
    }

    private func translatePIDToProcessObject(_ pid: Int32) -> AudioObjectID? {
        var processObject: AudioObjectID = 0
        var mutablePid = pid
        let status = getProperty(of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: &mutablePid, value: &processObject)
        guard status == noErr, processObject != kAudioObjectUnknown else {
            Logger.error("Failed to translate PID", metadata: ["pid": "\(pid)", "status": "\(status)"])
            return nil
        }
        return processObject
    }

    private func assertMain() {
        assert(Thread.isMainThread, "DeviceTapManager methods must be called on main thread")
    }

    deinit {
        unregisterDeviceListListener()
        for (_, tap) in taps {
            AudioHardwareDestroyProcessTap(tap.tapID)
        }
        taps.removeAll()
        DeviceTapManager.shared = nil
    }
}
