import CoreAudio
import Foundation
import Observation

struct InputDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
}

/// Enumerates CoreAudio input devices, keeps the user's priority list in sync,
/// and resolves which device to use right now.
@MainActor @Observable
final class MicrophoneManager {
    static let shared = MicrophoneManager()

    private(set) var devices: [InputDevice] = []

    private init() {
        refresh()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            MainActor.assumeIsolated { MicrophoneManager.shared.refresh() }
        }
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, .main) { _, _ in
            MainActor.assumeIsolated { MicrophoneManager.shared.refresh() }
        }
    }

    func refresh() {
        devices = Self.enumerate()
        // New devices join the end of the priority list; known ones keep their place.
        var list = AppSettings.shared.config.microphones
        var changed = false
        for d in devices {
            if let i = list.firstIndex(where: { $0.uid == d.uid }) {
                if list[i].name != d.name { list[i].name = d.name; changed = true }
            } else {
                list.append(MicRecord(uid: d.uid, name: d.name))
                changed = true
            }
        }
        if changed { AppSettings.shared.config.microphones = list }
    }

    func isConnected(_ uid: String) -> Bool { devices.contains { $0.uid == uid } }

    /// Candidate devices in priority order: enabled & connected ones from the
    /// user's list, then the system default as a last resort.
    func candidates() -> [InputDevice] {
        var out: [InputDevice] = []
        for rec in AppSettings.shared.config.microphones where rec.enabled {
            if let d = devices.first(where: { $0.uid == rec.uid }) { out.append(d) }
        }
        if let def = devices.first(where: \.isDefault), !out.contains(def) { out.append(def) }
        return out
    }

    // MARK: CoreAudio plumbing

    private static func enumerate() -> [InputDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let def = defaultInput()
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Hide aggregate/virtual devices created by other apps' internals.
            if uid.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return InputDevice(id: id, uid: uid, name: name, isDefault: id == def)
        }
    }

    static func defaultInput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
