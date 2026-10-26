import AppKit
import Carbon
import CaptureCore

@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var currentShortcut: Shortcut?
    private(set) var isSuspended = false
    var isRegistered: Bool { hotKey != nil }
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x43505452
    var onCapture: (() -> Void)?

    private static var nextIdentifier: UInt32 = 0
    let identifier: UInt32
    init() {
        Self.nextIdentifier += 1; identifier = Self.nextIdentifier
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x43505452 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue()
            guard identifier.id == manager.identifier else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { if !manager.isSuspended { manager.onCapture?() } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) throws {
        guard shortcut.isValid else { throw CaptureFailure.shortcutInUse }
        if shortcut == currentShortcut, hotKey != nil { return }
        guard !Self.isSystemShortcut(shortcut) else { throw ShortcutRegistrationError.systemReserved }
        let candidate = try createRegistration(shortcut)
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if isSuspended {
            UnregisterEventHotKey(candidate)
            hotKey = nil
        } else { hotKey = candidate }
        currentShortcut = shortcut
    }
    private func createRegistration(_ shortcut: Shortcut) throws -> EventHotKeyRef {
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: signature, id: identifier),
                                        GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr, let candidate else { throw CaptureFailure.shortcutInUse }
        return candidate
    }
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregister()
    }
    func resume() throws {
        guard isSuspended else { return }
        defer { isSuspended = false }
        if let currentShortcut { hotKey = try createRegistration(currentShortcut) }
    }
    static func isSystemShortcut(_ shortcut: Shortcut) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let values = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask: UInt32 = (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)
        return values.contains { item in
            (item[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true &&
            (item[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == shortcut.keyCode &&
            ((item[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value ?? 0) & mask == shortcut.modifiers
        }
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    }
    func dispose() {
        currentShortcut = nil
        isSuspended = false
        unregister()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

private enum ShortcutRegistrationError: LocalizedError {
    case systemReserved
    var errorDescription: String? { "这个组合已被 macOS 的系统快捷键占用，请选择其他组合。" }
}
