import AppKit
import SwiftUI
import CaptureCore
import ScreenCaptureKit

@MainActor
enum DeveloperChecks {
    static func run(at directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = directory.appendingPathComponent("isolated-preferences.json")
        try PreferencesIO.save(AppPreferences(), to: settings)
        let store = AppStore(url: settings)
        let privateBoard = NSPasteboard.withUniqueName()
        defer { privateBoard.releaseGlobally() }
        let app = AppController(store: store, clipboard: privateBoard, libraryDirectory: directory.appendingPathComponent("isolated-library"), recordingDirectory: directory.appendingPathComponent("isolated-recordings"))
        if CommandLine.arguments.contains("--quick-recording-only") {
            try await QuickRecordingChecks.run(app:app,directory:directory);app.stop();return
        }
        if CommandLine.arguments.contains("--recording-only") {
            try await RecordingChecks.run(store:store,directory:directory,screen:CommandLine.arguments.contains("--recording-screen-check")); app.stop(); return
        }
        if CommandLine.arguments.contains("--login-item-system") {
            try await LoginItemChecks.checkSystem(directory: directory)
            app.stop(); return
        }
        if CommandLine.arguments.contains("--login-item-only") {
            let checks = try await LoginItemChecks.run(directory: directory)
            try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks, "generalClipboardModified": false, "screenCaptureAttempted": false, "systemLoginItemModified": false], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("login-checks.json"))
            app.stop(); return
        }
        if CommandLine.arguments.contains("--editor-performance") {
            try await EditorPerformanceChecks.run(app: app, directory: directory)
            app.stop(); return
        }
        if CommandLine.arguments.contains("--workflow-only") {
            let checks = try await WorkflowChecks.run(app: app, board: privateBoard, directory: directory)
            try JSONSerialization.data(withJSONObject: ["result":"passed", "checks":checks, "generalClipboardModified":false, "screenCaptureAttempted":false], options:[.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("workflow-checks.json"))
            app.stop(); return
        }
        if CommandLine.arguments.contains("--floating-only") {
            _ = try FloatingAlignmentChecks.run(directory: directory); app.stop(); return
        }
        if CommandLine.arguments.contains("--selection-only") {
            _ = try await checkSelection(store: store, directory: directory)
            app.stop()
            return
        }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            throw CheckBlocked("桌面仍锁屏；键盘焦点与真实屏幕采集尚未执行，请解锁后重跑。")
        }
        let floatingChecks = try FloatingAlignmentChecks.run(directory: directory)
        let studioChecks = try await StudioControlChecks.run(directory: directory)
        let shortcutChecks = try ShortcutChecks.run()
        let source = SampleImage.make()
        let document = CaptureDocument(image: source, style: CaptureStyle(), useStyle: true, isSample: true)
        document.onStyleChange = { style in store.useStyle(style) }
        var changed = document.style; changed.padding = 144
        document.setStyle(changed)
        guard document.canUndo else { throw CheckFailure("编辑历史没有记录样式更改") }
        document.undo()
        guard document.style.padding == 96, document.canRedo else { throw CheckFailure("撤销失败") }
        document.redo()
        guard document.style.padding == 144 else { throw CheckFailure("重做失败") }
        document.reset()
        for _ in 0..<80 {
            if document.preview != nil && !document.rendering { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard document.preview != nil, document.message == nil else { throw CheckFailure(document.message ?? "预览渲染超时") }
        let previewPixels = document.preview!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        guard previewPixels.width == 1632, previewPixels.height == 1092 else { throw CheckFailure("Retina 预览被过早缩小") }
        let styled = try await document.rendered()
        guard styled.width == 1632, styled.height == 1092 else { throw CheckFailure("示例图片或渲染像素尺寸错误") }
        try ClipboardService.write(styled, to: privateBoard)
        guard let png = privateBoard.data(forType: .png), privateBoard.data(forType: .tiff) != nil else { throw CheckFailure("剪贴板缺少 PNG/TIFF 图像") }
        try png.write(to: directory.appendingPathComponent("styled.png"), options: .atomic)
        try StyleCompositor.encode(source).write(to: directory.appendingPathComponent("original.png"), options: .atomic)
        store.update { $0.automaticStyle = false }
        store.flush()
        let restored = try PreferencesIO.load(from: settings)
        guard !restored.automaticStyle, restored.activeStyle == document.style else { throw CheckFailure("关闭样式后未正确保留参数") }
        store.update { $0.automaticStyle = true }
        store.flush()
        try await snapshot(EditorView(document: document, store: store, app: app), name: "editor-light.png", width: 1060, height: 720, appearance: .light, directory: directory)
        try await snapshot(EditorView(document: document, store: store, app: app), name: "editor-dark.png", width: 1060, height: 720, appearance: .dark, directory: directory)
        let editingChecks = try await checkEditing(source: source, app: app, board: privateBoard, directory: directory)
        let presetChecks = try checkPresets(source: source, directory: directory)
        let selectionChecks = try await checkSelection(store: store, directory: directory)
        let interactionChecks = try await InteractionChecks.run(app: app, board: privateBoard, directory: directory)
        var frameStyle = document.style; frameStyle.windowFrame = true; frameStyle.windowTitle = "Notes — 今日计划"; frameStyle.windowAppearance = .light
        document.setStyle(frameStyle)
        try StyleCompositor.encode(try await document.rendered()).write(to: directory.appendingPathComponent("window-light.png"))
        try await snapshot(EditorView(document: document, store: store, app: app, initialTab: .effects), name: "window-editor-light.png", width: 1120, height: 760, appearance: .light, directory: directory)
        frameStyle.windowAppearance = .dark; document.setStyle(frameStyle)
        try StyleCompositor.encode(try await document.rendered()).write(to: directory.appendingPathComponent("window-dark.png"))
        try await snapshot(EditorView(document: document, store: store, app: app, initialTab: .effects), name: "window-editor-dark.png", width: 1120, height: 760, appearance: .dark, directory: directory)
        store.savePreset(name: "深色窗口 · 分享", style: frameStyle, makeDefault: true)
        frameStyle.windowAppearance = .light; store.savePreset(name: "浅色窗口 · 文档", style: frameStyle)
        try await snapshot(PresetsView(store: store, app: app, source: source, document: document), name: "presets.png", width: 920, height: 640, appearance: .light, directory: directory)
        try await snapshot(MenuView(store: store, app: app), name: "menu.png", width: 324, height: 590, appearance: .light, directory: directory)
        try await snapshot(SettingsView(store: store, app: app), name: "settings.png", width: 520, height: 530, appearance: .light, directory: directory)
        try await snapshot(RecentCapturesView(app: app), name: "recent.png", width: 740, height: 550, appearance: .light, directory: directory)
        try await snapshot(ThumbnailView(document: document, app: app, onHover: { _ in }, onClose: {}), name: "thumbnail.png", width: 326, height: 270, appearance: .light, directory: directory)
        let workflowChecks = try await WorkflowChecks.run(app: app, board: privateBoard, directory: directory)
        let realCapture = CommandLine.arguments.contains("--screen-check") ? await checkOwnWindow(source: source, directory: directory) : ["result": "not-requested"]
        let frozenChecks = realCapture["result"] as? String == "passed" ? try await FrozenCaptureChecks.run(directory: directory) : []
        let screenChecks = realCapture["result"] as? String == "passed" ? ["real-window-native-resolution", "real-region-native-resolution", "real-region-content-alignment"] : []
        let screenRequested = CommandLine.arguments.contains("--screen-check")
        let screenResult = realCapture["result"] as? String
        let screenBlocked = screenRequested && screenResult == "permission-required"
        let screenFailed = screenRequested && screenResult != "passed" && !screenBlocked
        var completedChecks: [String] = ["native-preview", "retina-preview-preserves-source-resolution", "undo-redo", "png-tiff-private-pasteboard", "automatic-style-retention", "light-dark-ui", "light-dark-window-chrome"]
        for group in [floatingChecks, studioChecks, shortcutChecks, editingChecks, presetChecks, interactionChecks, selectionChecks, workflowChecks, screenChecks, frozenChecks] {
            completedChecks.append(contentsOf: group)
        }
        let report: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "checks": completedChecks,
            "sourcePixels": [source.width, source.height], "outputPixels": [styled.width, styled.height],
            "generalClipboardModified": false, "screenCaptureAttempted": realCapture["attempted"] as? Bool ?? false,
            "ownWindowCapture": realCapture,
            "screenPermission": CGPreflightScreenCaptureAccess(),
            "result": screenBlocked ? "blocked" : (screenFailed ? "failed" : "passed")
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("checks.json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
        if screenBlocked { throw CheckBlocked("缺少屏幕录制权限；真实截图检查未执行，不能计为通过。") }
        if screenFailed { throw CheckFailure(realCapture["error"] as? String ?? "真实截图检查失败") }
        app.stop()
    }
    private static func checkSelection(store: AppStore, directory: URL) async throws -> [String] {
        let checks = try await SelectionChecks.run(store: store, directory: directory)
        let report: [String: Any] = ["result": "passed", "checks": checks, "scope": "Local events and native menu on an app-owned nonactivating panel over a generated sample; no screen read or general clipboard write. Physical keyboard focus and capture confirmation require an unlocked desktop."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("selection-checks.json"), options: .atomic)
        return checks
    }
    private static func checkOwnWindow(source: CGImage, directory: URL) async -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { return ["result": "permission-required", "attempted": false] }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Capture · 合成测试图"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Image(nsImage: NSImage(cgImage: source, size: CGSize(width: source.width, height: source.height))).resizable().scaledToFit())
        window.center(); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        guard let screen = window.screen else { return ["result": "failed", "attempted": false, "error": "没有可用显示器"] }
        // A second, black test window preserves display coordinates. ScreenCaptureKit
        // treats a filter containing a single window as an origin-zero window capture.
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = .black; backdrop.isOpaque = true; backdrop.isReleasedWhenClosed = false
        backdrop.orderBack(nil)
        defer { backdrop.orderOut(nil); backdrop.close() }
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let image = try await ScreenCaptureService.captureSample(windowID: CGWindowID(window.windowNumber), size: window.frame.size, scale: Double(window.screen?.backingScaleFactor ?? 1))
            guard image.width > 100, image.height > 100 else { throw CheckFailure("真实窗口截图尺寸无效") }
            try StyleCompositor.encode(image).write(to: directory.appendingPathComponent("real-own-window.png"))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let captured = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
                  let background = content.windows.first(where: { $0.windowID == CGWindowID(backdrop.windowNumber) }),
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else { throw CheckFailure("找不到本应用的测试窗口或显示器") }
            let windowFilter = SCContentFilter(desktopIndependentWindow: captured)
            let windowConfiguration = try ScreenCaptureService.nativeConfiguration(filter: windowFilter, fallbackSize: captured.frame.size, fallbackScale: screen.backingScaleFactor, includeCursor: false)
            guard windowConfiguration.captureResolution == .best,
                  image.width == windowConfiguration.width, image.height == windowConfiguration.height else { throw CheckFailure("窗口截图未保留原生分辨率") }
            // Including only this generated window keeps other applications out of diagnostics.
            let displayFilter = SCContentFilter(display: display, including: [background, captured])
            let displayConfiguration = try ScreenCaptureService.nativeConfiguration(filter: displayFilter, fallbackSize: display.frame.size, fallbackScale: screen.backingScaleFactor, includeCursor: false)
            displayConfiguration.ignoreGlobalClipSingleWindow = false
            let full = try await SCScreenshotManager.captureImage(contentFilter: displayFilter, configuration: displayConfiguration)
            try StyleCompositor.encode(full).write(to: directory.appendingPathComponent("real-own-filtered-display.png"))
            let rect = CGRect(x: captured.frame.minX - display.frame.minX, y: captured.frame.minY - display.frame.minY,
                              width: captured.frame.width, height: captured.frame.height)
            let region = try await ScreenCaptureService.captureRegion(filter: displayFilter, selection: rect, fallbackScale: screen.backingScaleFactor)
            let expected = SelectionGeometry.pixelRectangle(for: rect, backingScale: Double(displayFilter.pointPixelScale)).size
            guard region.width == Int(expected.width), region.height == Int(expected.height),
                  region.bytesPerRow == region.width * 4 else { throw CheckFailure("区域截图未保留紧凑的原生像素") }
            try StyleCompositor.encode(region).write(to: directory.appendingPathComponent("real-own-region.png"))
            let windowText = try await Task.detached { try TextRecognition.recognize(image) }.value
            let regionText = try await Task.detached { try TextRecognition.recognize(region) }.value
            guard let windowAnchor = windowText.lines.first(where: { $0.text.contains("空白") }),
                  let regionAnchor = regionText.lines.first(where: { $0.text.contains("空白") }),
                  abs(windowAnchor.bounds.x - regionAnchor.bounds.x) < 0.005,
                  abs(windowAnchor.bounds.y - regionAnchor.bounds.y) < 0.005 else { throw CheckFailure("区域裁剪与真实窗口内容位置不一致") }
            return ["result": "passed", "attempted": true, "scope": "this app's generated sample and black backdrop only; all other windows excluded", "pixels": [image.width, image.height],
                    "regionPixels": [region.width, region.height], "pointPixelScale": displayFilter.pointPixelScale, "captureResolution": "best",
                    "displayFrame": NSStringFromRect(display.frame), "filterRect": NSStringFromRect(displayFilter.contentRect), "windowFrame": NSStringFromRect(captured.frame),
                    "selectedRect": NSStringFromRect(rect), "fullPixels": [full.width, full.height], "regionContentAlignment": "passed; OCR anchor matches independent window within 0.5%",
                    "regionBytesPerRow": region.bytesPerRow, "regionOwnsCompactPixels": true]
        } catch { return ["result": "failed", "attempted": true, "error": error.localizedDescription] }
    }
    private static func checkPresets(source: CGImage, directory: URL) throws -> [String] {
        let path = directory.appendingPathComponent("preset-check-preferences.json")
        try PreferencesIO.save(AppPreferences(), to: path)
        let store = AppStore(url: path)
        var dark = CaptureStyle(); dark.windowFrame = true; dark.windowAppearance = .dark; dark.windowTitle = "Project"
        let first = try requireID(store.savePreset(name: "默认窗口", style: dark, makeDefault: true))
        let second = try requireID(store.savePreset(name: "浅色文档", style: StylePreset.builtIns[1].style))
        store.useStyle(StylePreset.builtIns[2].style)
        guard store.preferences.defaultPresetID == first, store.captureStyle == dark else { throw CheckFailure("临时调整覆盖了默认预设") }
        store.renamePreset(first, name: "工作分享")
        guard store.defaultName == "工作分享", store.preferences.defaultPresetID == first else { throw CheckFailure("重命名丢失默认身份") }
        store.update { $0.automaticStyle = false }; store.flush()
        let restored = AppStore(url: path)
        guard restored.preferences.defaultPresetID == first, restored.captureStyle == dark, !restored.preferences.automaticStyle else { throw CheckFailure("默认预设或自动样式开关没有持久保存") }
        let count = restored.preferences.customPresets.count
        guard restored.savePreset(name: "工作分享", style: dark) == nil, restored.preferences.customPresets.count == count else { throw CheckFailure("重复名称未被拒绝") }
        restored.deletePreset(first)
        guard restored.preferences.defaultPresetID == StylePreset.builtIns[0].id, restored.presets.contains(where: { $0.id == second }) else { throw CheckFailure("删除默认预设后没有安全回退") }
        let legacyPath = directory.appendingPathComponent("legacy-preset-preferences.json")
        var legacy = AppPreferences(); legacy.activeStyle = dark
        try PreferencesIO.save(legacy, to: legacyPath)
        let migrated = AppStore(url: legacyPath)
        guard migrated.defaultPreset != nil, migrated.captureStyle == dark else { throw CheckFailure("旧的默认样式迁移时丢失") }
        return ["multiple-named-presets", "explicit-default-preset", "temporary-edits-do-not-replace-default", "preset-rename-keeps-identity", "default-preset-and-toggle-persistence", "duplicate-preset-name-rejected", "delete-default-fallback", "legacy-default-style-migration"]
    }
    private static func requireID(_ id: String?) throws -> String {
        guard let id else { throw CheckFailure("无法保存测试预设") }; return id
    }
    private static func checkEditing(source: CGImage, app: AppController, board: NSPasteboard, directory: URL) async throws -> [String] {
        let document = CaptureDocument(image: source, style: CaptureStyle(), useStyle: false)
        document.addAnnotation(Annotation(kind: .arrow, start: UnitPoint(0.2, 0.3), end: UnitPoint(0.6, 0.5)))
        document.addAnnotation(Annotation(kind: .redact, start: UnitPoint(0.63, 0.2), end: UnitPoint(0.91, 0.3)))
        document.addAnnotation(Annotation(kind: .counter, start: UnitPoint(0.32, 0.5), end: UnitPoint(0.32, 0.5), text: "1"))
        let captured = try await document.rendered()
        guard captured.width == source.width, document.edits.annotations.count == 3, !document.useStyle else { throw CheckFailure("普通截图中的编辑没有保留") }
        document.undo(); guard document.edits.annotations.count == 2 else { throw CheckFailure("标注撤销失败") }
        document.redo(); guard document.edits.annotations.count == 3 else { throw CheckFailure("标注重做失败") }
        document.groupChanges(true)
        for padding in [100.0, 120, 140] { var style = document.style; style.padding = padding; document.setStyle(style) }
        document.groupChanges(false); document.undo()
        guard document.style.padding == 96, !document.useStyle else { throw CheckFailure("拖动滑块没有合并成一次撤销") }
        document.outputScale = 0.5
        let window = CaptureEditorWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.captureDocument = document; window.captureApp = app
        defer { window.close() }
        let previousCount = board.changeCount
        guard NSApp.sendAction(#selector(CaptureEditorWindow.copy(_:)), to: window, from: nil) else { throw CheckFailure("原生复制命令没有处理") }
        for _ in 0..<60 {
            if board.changeCount > previousCount && !app.copying { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let data = board.data(forType: .png) else { throw CheckFailure("原生复制命令没有输出图片") }
        let copied = try StyleCompositor.decode(data)
        guard copied.width == source.width / 2, copied.height == source.height / 2 else { throw CheckFailure("复制倍率与导出设置不一致") }
        guard let small = source.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 160)) else { throw CheckFailure("无法生成历史验证图片") }
        for _ in 0..<14 { app.remember(CaptureDocument(image: small, style: CaptureStyle(), useStyle: false)) }
        guard app.recentDocuments.count == 12 else { throw CheckFailure("最近截图数量没有限制") }
        let last = app.recentDocuments[0]; app.removeRecent(last)
        guard app.lastDocument?.id == app.recentDocuments.first?.id else { throw CheckFailure("移除最近截图后入口失效") }
        try await snapshot(EditorView(document: document, store: app.store, app: app, initialTab: .markup), name: "markup.png", width: 1120, height: 760, appearance: .light, directory: directory)
        let recognized = try await Task.detached(priority: .userInitiated) { try TextRecognition.recognize(source) }.value
        guard !recognized.lines.isEmpty else { throw CheckFailure("示例图片 OCR 未识别到文字") }
        let sensitive = RecognizedLine(text: "联系 hello@example.com", bounds: UnitRect())
        guard sensitive.isSensitive else { throw CheckFailure("敏感信息候选检测失败") }
        try await snapshot(RecognitionView(document: document), name: "ocr.png", width: 640, height: 540, appearance: .light, directory: directory)
        return ["annotation-undo-redo", "plain-mode-preserves-edits", "slider-undo-grouping", "native-copy-action", "copy-respects-export-scale", "bounded-session-history", "ocr-on-generated-image", "sensitive-line-detection"]
    }
    static func snapshot<V: View>(_ view: V, name: String, width: Double, height: Double, appearance: ColorScheme, directory: URL, delayNanoseconds: UInt64 = 180_000_000) async throws {
        let content = view.frame(width: width, height: height).background(CaptureTheme.chrome).environment(\.colorScheme, appearance)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: delayNanoseconds)
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CheckFailure("无法导出原生界面预览：\(name)") }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let image = representation.cgImage else { throw CheckFailure("原生界面预览为空：\(name)") }
        try StyleCompositor.encode(image).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    struct CheckFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    struct CheckBlocked: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
