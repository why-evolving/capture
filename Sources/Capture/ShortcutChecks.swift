import AppKit
import CaptureCore

@MainActor
enum ShortcutChecks {
    static func run() throws -> [String] {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw DeveloperChecks.CheckFailure(message) }
        }
        let manager = GlobalHotKey()
        let allModifiers: UInt32 = (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)
        let old = Shortcut(keyCode: 90, modifiers: allModifiers, keyLabel: "F20")
        let replacement = Shortcut(keyCode: 79, modifiers: allModifiers, keyLabel: "F18")
        try manager.register(old)
        defer { manager.dispose() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = RecorderView(frame: CGRect(x: 30, y: 30, width: 180, height: 35))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 100))
        root.addSubview(recorder); window.contentView = root
        defer { recorder.endRecording(); window.close() }
        var transitions: [Bool] = []
        var registrationError: String?
        var committed: Shortcut?
        recorder.onRecordingChange = { active in
            transitions.append(active)
            if active { manager.suspend() }
            else { do { try manager.resume() } catch { registrationError = error.localizedDescription } }
        }
        recorder.onChange = { candidate in
            do { try manager.register(candidate); committed = candidate; return nil }
            catch { return error.localizedDescription }
        }
        func event(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let shiftedTwo = event(.keyDown, code: 19, flags: [.command, .shift], characters: "@")
        let translated = RecorderView.shortcut(from: shiftedTwo)
        try require(translated?.keyLabel == "2", "⇧2 应显示数字 2，而不是 @")
        try require(translated?.display == Shortcut.defaultCapture.display, "快捷键修饰符显示错误")

        recorder.beginRecording()
        try require(recorder.isRecording && manager.isSuspended && !manager.isRegistered, "开始录制时未暂停截图热键")
        let command = event(.keyDown, code: 79, flags: [.command, .option, .control, .shift], characters: "")
        try require(recorder.consume(command), "录制时未消费 Command 组合键")
        try require(committed == replacement && recorder.waitingForRelease, "新组合键未正确保存")
        try require(manager.isSuspended && !manager.isRegistered, "按键尚未松开就恢复了截图热键")
        recorder.consume(event(.keyUp, code: 79, flags: [.command, .option, .control, .shift], characters: ""))
        try require(!recorder.isRecording && manager.isRegistered && !manager.isSuspended, "松开按键后未恢复热键")

        recorder.beginRecording()
        recorder.consume(command)
        recorder.consume(event(.flagsChanged, code: 55, flags: [], characters: ""))
        try require(!recorder.isRecording && manager.isRegistered, "Command 组合缺少 keyUp 时应通过修饰键松开结束录制")

        recorder.beginRecording()
        recorder.consume(event(.keyDown, code: 53, flags: [], characters: "\u{1b}"))
        try require(!recorder.isRecording && manager.isRegistered && committed == replacement, "Esc 未恢复原快捷键")
        try require(transitions == [true, false, true, false, true, false], "录制状态回调不成对")
        recorder.beginRecording()
        recorder.consume(event(.keyDown, code: 0, flags: [], characters: "a"))
        try require(recorder.isRecording && !recorder.waitingForRelease, "无修饰键输入不应提交")
        window.makeFirstResponder(nil)
        try require(!recorder.isRecording && manager.isRegistered, "离开输入框后未恢复截图热键")

        let conflicting = GlobalHotKey()
        defer { conflicting.dispose() }
        let occupied = Shortcut(keyCode: 80, modifiers: allModifiers, keyLabel: "F19")
        try conflicting.register(occupied)
        recorder.beginRecording()
        recorder.consume(event(.keyDown, code: 80, flags: [.command, .option, .control, .shift], characters: ""))
        try require(recorder.isRecording && !recorder.waitingForRelease, "冲突组合不应关闭录制")
        try require(committed == replacement, "冲突组合覆盖了原设置")
        recorder.endRecording()
        try require(manager.isRegistered && registrationError == nil, "冲突取消后未恢复原快捷键")

        // Verify the real NSApplication dispatch path: the monitor must consume
        // Command+Q before the test menu action, without sending a system event.
        let target = MenuProbe()
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        let top = NSMenuItem(); let submenu = NSMenu()
        let item = NSMenuItem(title: "Probe", action: #selector(MenuProbe.invoked), keyEquivalent: "q")
        item.target = target; submenu.addItem(item); top.submenu = submenu; menu.addItem(top)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }
        recorder.onChange = { candidate in committed = candidate; return "检查冲突反馈" }
        window.orderBack(nil)
        recorder.beginRecording()
        try require(window.firstResponder === recorder, "测试窗口未将按键焦点交给录制框")
        NSApp.sendEvent(event(.keyDown, code: 12, flags: [.command], characters: "q"))
        try require(committed?.keyCode == 12 && !target.wasInvoked, "Command 组合键被菜单先处理")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try require(!recorder.isRecording && manager.isRegistered, "窗口失焦后未清理录制和热键状态")
        return ["command-event-routing", "hotkey-suspend-until-keyup", "escape-restores-hotkey",
                "focus-loss-restores-hotkey", "conflict-retains-previous-shortcut", "shift-number-label",
                "modifier-release-fallback"]
    }
}

private final class MenuProbe: NSObject {
    var wasInvoked = false
    @objc func invoked() { wasInvoked = true }
}
