import AppKit
import CaptureCore

final class RecorderView: NSView {
    var shortcut = Shortcut.defaultCapture
    var onChange: ((Shortcut) -> String?)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private(set) var waitingForRelease = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingKey: UInt16?
    private var pendingModifiers: UInt32 = 0
    private var recordingText = "按下快捷键…"

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endRecording(releaseFocus: false) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resignFirstResponder() -> Bool { endRecording(releaseFocus: false); return true }

    func beginRecording() {
        guard !isRecording, let window, window.makeFirstResponder(self) else { return }
        isRecording = true; pendingKey = nil; pendingModifiers = 0; waitingForRelease = false
        recordingText = "按下快捷键…"
        // Local monitors run before menu key equivalents. A responder override
        // alone cannot reliably receive Command shortcuts from NSHostingView.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording, let window = self.window,
                  window.firstResponder === self,
                  event.window == nil || event.window === window else { return event }
            return self.consume(event) ? nil : event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRecording(releaseFocus: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endRecording(releaseFocus: false) }
        })
        onRecordingChange?(true)
        needsDisplay = true
    }
    func endRecording(releaseFocus: Bool = true) {
        guard isRecording else { return }
        isRecording = false; pendingKey = nil; pendingModifiers = 0; waitingForRelease = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onRecordingChange?(false)
        needsDisplay = true
        if releaseFocus, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    /// Shared by the local monitor, responder fallback, and isolated native checks.
    @discardableResult
    func consume(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.type == .keyUp {
            if pendingKey == event.keyCode { endRecording() }
            return true
        }
        if event.type == .flagsChanged {
            if waitingForRelease, Self.carbonModifiers(event.modifierFlags) & pendingModifiers != pendingModifiers {
                // Some Command combinations omit the primary keyUp in AppKit.
                // Releasing a required modifier also makes re-registration safe.
                endRecording()
                return true
            }
            if !waitingForRelease {
                let modifiers = Self.carbonModifiers(event.modifierFlags)
                let glyphs = Shortcut(keyCode: 0, modifiers: modifiers, keyLabel: "").display
                recordingText = glyphs.isEmpty ? "按下快捷键…" : glyphs + "…"
                needsDisplay = true
            }
            return true
        }
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 { endRecording(); return true }
        if event.isARepeat || waitingForRelease { return true }
        guard let candidate = Self.shortcut(from: event) else {
            recordingText = "请加 ⌘、⌥ 或 ⌃"; needsDisplay = true; return true
        }
        if onChange?(candidate) != nil {
            recordingText = "组合已占用，请重试"; needsDisplay = true; return true
        }
        shortcut = candidate
        pendingKey = event.keyCode
        pendingModifiers = candidate.modifiers
        waitingForRelease = true
        recordingText = candidate.display + " · 松开完成"
        needsDisplay = true
        // Keep Capture's hotkey suspended until the primary key is released;
        // holding the new combination must not start a screenshot immediately.
        return true
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= 1 << 8 }; if flags.contains(.shift) { value |= 1 << 9 }
        if flags.contains(.option) { value |= 1 << 11 }; if flags.contains(.control) { value |= 1 << 12 }
        return value
    }
    static func shortcut(from event: NSEvent) -> Shortcut? {
        guard event.type == .keyDown else { return nil }
        let modifiers = carbonModifiers(event.modifierFlags)
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 76: "⌅", 117: "⌦",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        // charactersIgnoringModifiers preserves Shift (⇧2 becomes "@").
        // Re-translate the physical key with no modifiers using the active layout.
        let label = special[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased()
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)"
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }
    override func keyDown(with event: NSEvent) { if !consume(event) { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if !consume(event) { super.keyUp(with: event) } }
    override func flagsChanged(with event: NSEvent) { if !consume(event) { super.flagsChanged(with: event) } }
    override func cancelOperation(_ sender: Any?) { endRecording() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        consume(event) || super.performKeyEquivalent(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1; path.stroke()
        let text = isRecording ? recordingText : shortcut.display
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: bounds.insetBy(dx: 4, dy: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: isRecording ? 12 : 14, weight: .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
    }
}
