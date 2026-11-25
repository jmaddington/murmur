import AppKit
import Carbon.HIToolbox

/// Unified press/release events for either a bare modifier (fn, right ⌥ ...)
/// or a regular shortcut (⌥Space ...). The controller turns these into
/// push-to-talk (hold) or hands-free (quick tap) behaviour.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Both carry the event's own timestamp (seconds since boot, like
    /// `NSEvent.timestamp`): events can be delivered late while the main thread
    /// is busy opening the microphone, and tap-vs-hold must be judged on when
    /// the key actually moved, not on when the handler got to run.
    var onPress: ((TimeInterval) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// Another key was pressed while the trigger modifier was held — it's a chord, not dictation.
    var onChord: (() -> Void)?
    var onEscape: (() -> Void)?
    /// The separate hands-free shortcut was pressed.
    var onToggle: (() -> Void)?

    private var monitors: [Any] = []
    private var hotKeyRef: EventHotKeyRef?
    private var toggleRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var modifierDown = false
    private(set) var suspended = false

    func install() {
        uninstall()
        let c = AppSettings.shared.config
        switch c.triggerKind {
        case .modifier: installModifier(c.triggerModifier)
        case .shortcut: installShortcut(c.shortcut)
        }
        if c.handsFreeShortcutEnabled && !(c.triggerKind == .shortcut && c.shortcut == c.handsFreeShortcut) {
            installCarbonHandler()
            let id = EventHotKeyID(signature: OSType(0x4D524D52), id: 2)
            RegisterEventHotKey(c.handsFreeShortcut.keyCode, Self.carbonModifiers(c.handsFreeShortcut.modifiers), id,
                                GetApplicationEventTarget(), 0, &toggleRef)
        }
        // Escape cancels; keyDown also detects chords for the modifier trigger.
        let keyHandler: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            if e.keyCode == UInt16(kVK_Escape) { self.onEscape?() }
            else if self.modifierDown { self.onChord?() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keyHandler($0); return $0 }) { monitors.append(m) }
    }

    /// Temporarily disable while the shortcut recorder is capturing keys.
    func setSuspended(_ s: Bool) {
        suspended = s
        if s { uninstall() } else { install() }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let toggleRef { UnregisterEventHotKey(toggleRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        toggleRef = nil
        handlerRef = nil
        modifierDown = false
    }

    // MARK: Modifier

    private func installModifier(_ mod: TriggerModifier) {
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.keyCode == mod.keyCode else { return }
            let down = mod.isDown(in: e.modifierFlags)
            if down && !self.modifierDown {
                self.modifierDown = true
                self.onPress?(e.timestamp)
            } else if !down && self.modifierDown {
                self.modifierDown = false
                self.onRelease?(e.timestamp)
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(m) }
    }

    // MARK: Shortcut (Carbon — works without Accessibility)

    /// One Carbon handler serves both hot keys: id 1 = push-to-talk shortcut,
    /// id 2 = hands-free toggle.
    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let kind = GetEventKind(event)
            let time = GetEventTime(event)
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = kind == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated {
                let m = HotkeyManager.shared
                if hk.id == 2 { if pressed { m.onToggle?() } }
                else if pressed { m.onPress?(time) }
                else { m.onRelease?(time) }
            }
            return noErr
        }, 2, &types, nil, &handlerRef)
    }

    private func installShortcut(_ combo: KeyCombo) {
        installCarbonHandler()
        guard handlerRef != nil else { return }
        let id = EventHotKeyID(signature: OSType(0x4D524D52), id: 1) // 'MRMR'
        RegisterEventHotKey(combo.keyCode, Self.carbonModifiers(combo.modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let f = NSEvent.ModifierFlags(rawValue: raw)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

extension TriggerModifier {
    /// Device-dependent (left/right) bits of `NSEvent.ModifierFlags.rawValue`,
    /// from IOKit's NX_DEVICE…KEYMASK: (this key, its twin on the other side).
    private var sideMasks: (own: UInt, twin: UInt)? {
        switch self {
        case .fn: nil
        case .rightOption: (0x40, 0x20)
        case .rightCommand: (0x10, 0x08)
        case .rightControl: (0x2000, 0x01)
        }
    }

    /// Whether *this* key is down after a flagsChanged event for its key code.
    /// The device-independent flag alone can't tell: releasing right ⌥ while
    /// left ⌥ is held still reports `.option`, which used to leave a
    /// push-to-talk recording running with the key up.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(flag) else { return false }
        guard let m = sideMasks, flags.rawValue & (m.own | m.twin) != 0 else { return true }
        return flags.rawValue & m.own != 0
    }
}

extension KeyCombo {
    var displayParts: [String] {
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var parts: [String] = []
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        ]
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let rc = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard rc == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}
