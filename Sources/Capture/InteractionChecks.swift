import AppKit
import SwiftUI
import CaptureCore
import UniformTypeIdentifiers

/// Exercises only this application's generated documents, private clipboard and panels.
@MainActor
enum InteractionChecks {
    static func run(app: AppController, board: NSPasteboard, directory: URL) async throws -> [String] {
        func phase(_ name: String) { try? Data(name.utf8).write(to: directory.appendingPathComponent("interaction-phase.txt"), options: .atomic) }
        phase("comparison-and-copy")
        let source = SampleImage.make(width: 600, height: 375)
        var style = CaptureStyle(); style.padding = 20; style.windowFrame = true
        let document = CaptureDocument(image: source, style: style, useStyle: true)
        document.addAnnotation(Annotation(kind: .redact, start: UnitPoint(0.15, 0.3), end: UnitPoint(0.7, 0.5)))
        let expected = try StyleCompositor.encode(try await document.rendered())
        let dimensions = document.exportLabel
        document.showOriginal = true
        try require(try await bytes(document) == expected, "对比原图改变了正常导出内容")
        try require(document.exportLabel == dimensions, "对比原图改变了导出尺寸")
        await app.copy(document)
        try require(board.data(forType: .png) == expected, "对比原图时复制丢失编辑或遮挡")
        let original = try await document.rendered(originalOnly: true)
        try require(original === source, "明确导出原图没有保留原始像素")
        phase("drag-data")
        let provider = document.itemProvider()
        defer { withExtendedLifetime(provider) {} }
        let dragged: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? DeveloperChecks.CheckFailure("拖放没有返回 PNG")) }
            }
        }
        try require(dragged == expected, "拖放与复制的成品不一致")
        phase("text-responder")
        let previousMenu = NSApp.mainMenu
        app.installMainMenu()
        defer { NSApp.mainMenu = previousMenu }
        let window = CaptureEditorWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.captureDocument = document; window.captureApp = app
        let host = NSHostingView(rootView: EditorView(document: document, store: app.store, app: app))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 640))
        host.frame = root.bounds; root.addSubview(host); window.contentView = root
        defer { window.close() }
        let text = AuditTextView(frame: CGRect(x: 20, y: 20, width: 150, height: 35))
        text.pasteboard = board; text.string = "只复制这段文字"; text.allowsUndo = true
        root.addSubview(text); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<40 {
            if NSApp.isActive && window.isKeyWindow { break }
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(NSApp.isActive && window.isKeyWindow, "原生键盘检查需要已解锁的桌面及测试窗口焦点")
        try require(window.makeFirstResponder(text), "无法将焦点交给原生文本输入框")
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        let commandC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        NSApp.sendEvent(commandC)
        try require(board.string(forType: .string) == text.string && board.data(forType: .png) == nil, "编辑文本时复制了整张图片")
        phase("text-undo")
        let beforeTextUndo = document.edits
        window.undo(nil)
        try require(document.edits == beforeTextUndo, "文本输入框没有可撤销内容时撤销了图片")
        window.makeFirstResponder(nil)
        document.selectedAnnotationID = document.edits.annotations.first?.id
        window.deleteBackward(nil)
        try require(document.edits.annotations.isEmpty && document.selectedAnnotationID == nil, "Delete 未移除选中标注或留下无效选择")
        window.undo(nil)
        try require(document.edits.annotations.count == 1, "标注删除不能撤销")
        let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        NSApp.sendEvent(commandW)
        try require(!window.isVisible, "⌘W 没有关闭当前窗口")
        window.orderOut(nil)
        phase("annotation-limit")
        var excessive = document.edits
        excessive.annotations = (0..<501).map { _ in Annotation(kind: .counter, start: UnitPoint(0.2, 0.2), end: UnitPoint(0.2, 0.2), text: "1") }
        try require(!document.setEdits(excessive) && document.edits.annotations.count == 1 && document.message != nil, "标注达到上限时没有保留编辑并提示")

        let fixtures = directory.appendingPathComponent("export-fixtures")
        phase("export-output")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        app.store.update { $0.saveDirectory = fixtures.path }
        let saved = fixtures.appendingPathComponent("edited-output.png")
        // Each self-check uses its own fixture directory; this file is generated here.
        if FileManager.default.fileExists(atPath: saved.path) { try FileManager.default.removeItem(at: saved) }
        document.filename = "edited-output"; document.outputFormat = .png; document.showOriginal = true
        let output = try await app.prepareExport(document)
        try require(output.suggestedName == saved.lastPathComponent, "保存文件名与输出格式不一致")
        try await app.writeExport(output, to: saved, document: document)
        try require(try Data(contentsOf: saved) == expected, "实际导出的文件与当前编辑成品不一致")
        document.filename = "cancelled-output"
        phase("cancel-save")
        app.save(document)
        let cancelledPanel = try await waitForPanel { app.activeSavePanel }
        try require(!app.canStartCapture, "保存面板打开时仍可启动截图")
        cancelledPanel.cancel(nil)
        try await waitUntil { !app.saving }
        try require(!FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("cancelled-output.png").path), "取消保存仍写入了文件")
        app.openImage()
        phase("cancel-open")
        let openPanel = try await waitForPanel { app.activeFilePanel }
        try require(app.choosingFiles && !app.canStartCapture, "选文件期间没有阻止截图或重复打开面板")
        app.openImage()
        try require(app.activeFilePanel === openPanel, "重复操作打开了第二个文件面板")
        openPanel.cancel(nil)
        try await waitUntil { !app.choosingFiles }
        try require(app.activeFilePanel == nil, "取消文件选择后状态没有恢复")

        let thumbnail = ThumbnailController()
        phase("thumbnail")
        thumbnail.show(document: document, screen: NSScreen.main, app: app)
        defer { thumbnail.dismiss() }
        try require(thumbnail.isVisible && thumbnail.hasScheduledDismissal, "缩略图没有显示或启动收起计时")
        let trackedMenu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: trackedMenu)
        try require(!thumbnail.hasScheduledDismissal, "菜单展开时缩略图仍在倒计时")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: trackedMenu)
        try require(thumbnail.hasScheduledDismissal, "菜单关闭后缩略图没有恢复计时")
        thumbnail.dismiss(); thumbnail.resume()
        try require(!thumbnail.isVisible && !thumbnail.hasScheduledDismissal, "已关闭缩略图仍重启了计时")

        let pins = PinController()
        phase("pinning")
        defer { pins.closeAll() }
        for _ in 0..<8 { try require(pins.show(source, document: document, app: app), "置顶数量未达到上限却被拒绝") }
        try require(!pins.show(source, document: document, app: app), "超过 8 张置顶仍继续创建窗口")
        pins.closeAll()
        try require(pins.show(source, document: document, app: app), "关闭置顶后没有释放数量限制")
        pins.closeAll()
        try require(app.copyPinnedImage(source), "复制置顶快照失败")
        try require(try board.data(forType: .png) == StyleCompositor.encode(source), "置顶复制改变了原快照")

        app.importClipboard()
        phase("clipboard-import")
        try await waitUntil { app.lastDocument?.original.width == source.width && app.lastDocument?.original.height == source.height }
        guard let imported = app.lastDocument else { throw DeveloperChecks.CheckFailure("剪贴板图片导入后没有可编辑文档") }
        for editor in NSApp.windows.compactMap({ $0 as? CaptureEditorWindow }) where editor.captureDocument === imported { editor.close() }

        var checks = ["original-comparison-is-view-only", "copy-keeps-redaction-during-comparison", "original-export-is-explicit", "drag-and-copy-share-edited-output", "text-copy-preserves-responder-chain", "text-undo-does-not-undo-image", "delete-annotation-and-undo", "command-w-closes-window", "annotation-limit-reports-failure", "export-writes-edited-output", "cancel-save-writes-nothing", "file-panel-prevents-reentry-and-capture", "cancel-file-panel-restores-state", "thumbnail-menu-pauses-timeout", "thumbnail-dismiss-does-not-restart-timeout", "pin-limit-and-close-recovery", "pin-copy-preserves-snapshot", "clipboard-import-opens-editable-document"]
        if CGPreflightScreenCaptureAccess() {
            phase("cancel-capture")
            let count = board.changeCount
            app.captureTestWindow(); try require(app.busy, "测试截图未进入工作状态")
            app.cancelCapture(); try require(!app.busy, "取消截图后仍处于工作状态")
            app.captureTestWindow()
            try await Task.sleep(nanoseconds: 50_000_000)
            try require(app.busy, "旧截图的取消任务干扰了新截图")
            app.cancelCapture()
            try await Task.sleep(nanoseconds: 50_000_000)
            try require(!app.busy && board.changeCount == count, "取消截图仍改写剪贴板或没有恢复状态")
            checks.append("cancel-and-recapture-isolated-sessions")
        }
        phase("passed")
        return checks
    }
    private static func bytes(_ document: CaptureDocument) async throws -> Data { try StyleCompositor.encode(try await document.rendered()) }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw DeveloperChecks.CheckFailure(message) } }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<120 { if predicate() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw DeveloperChecks.CheckFailure("原生面板操作等待超时")
    }
    private static func waitForPanel<T: NSSavePanel>(_ get: () -> T?) async throws -> T {
        try await waitUntil { get()?.isVisible == true }
        // The remote panel's view service must finish appearing before commands.
        try await Task.sleep(nanoseconds: 600_000_000)
        guard let panel = get() else { throw DeveloperChecks.CheckFailure("原生面板已意外关闭") }; return panel
    }
}

private final class AuditTextView: NSTextView {
    var pasteboard: NSPasteboard?
    override func copy(_ sender: Any?) {
        let value = (string as NSString).substring(with: selectedRange())
        pasteboard?.clearContents(); pasteboard?.setString(value, forType: .string)
    }
}
