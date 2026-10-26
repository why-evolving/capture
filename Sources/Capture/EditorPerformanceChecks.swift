import AppKit
import SwiftUI
import CaptureCore

/// Generated content, isolated settings, no screen capture or general clipboard writes.
@MainActor enum EditorPerformanceChecks {
    final class Selection: ObservableObject { @Published var tab: EditorTab = .background }
    struct Host: View {
        @ObservedObject var selection: Selection
        let document: CaptureDocument
        let app: AppController
        var body: some View {
            EditorView(document: document, store: app.store, app: app, tabSelection: $selection.tab)
        }
    }
    static func run(app: AppController, directory: URL) async throws {
        let document = CaptureDocument(image: SampleImage.make(width: 3840, height: 2160), style: CaptureStyle(), useStyle: true, isSample: true)
        for _ in 0..<100 { if !document.rendering { break }; try await Task.sleep(for: .milliseconds(30)) }
        guard !document.rendering, document.preview != nil else { throw DeveloperChecks.CheckFailure("性能样例预览未完成") }
        let initialPreview = document.preview, initialContent = document.contentPreview
        let initialStyle = document.style, initialEdits = document.edits
        let click = CommandLine.arguments.contains("--performance-clicks")
        let compact = CommandLine.arguments.contains("--performance-compact")
        let selection = Selection()
        let host = NSHostingView(rootView: Host(selection: selection, document: document, app: app))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: compact ? 900 : 1120, height: compact ? 640 : 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.title = "Capture · 标签性能测试"; window.isReleasedWhenClosed = false
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let image = bitmap.cgImage { try StyleCompositor.encode(image).write(to: directory.appendingPathComponent("fixture.png")) }
        }
        var measurements: [[String: Any]] = []
        for cycle in 0..<(click ? 6 : (CommandLine.arguments.contains("--performance-extended") ? 10 : 3)) {
            for tab in [EditorTab.markup, .layout, .effects, .export, .background] {
                // Exercise the label centre and transparent left/right/top/bottom padding.
                let row = EditorTab.allCases.firstIndex(of: tab)!
                let top = 62.0 + 1 + 14 + 26 + Double(row) * 62
                let offsets: [CGPoint] = [.zero, CGPoint(x: -18, y: 0), CGPoint(x: 18, y: 0), CGPoint(x: 0, y: -22), CGPoint(x: 0, y: 22), .zero]
                let offset = click ? offsets[cycle] : .zero
                let hitY = top + offset.y
                let point = host.convert(CGPoint(x: 28.5 + offset.x, y: host.isFlipped ? hitY : host.bounds.height - hitY), to: nil)
                let start = CFAbsoluteTimeGetCurrent()
                if click {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                        NSApp.postEvent(event, atStart: false)
                    }
                    for _ in 0..<400 {
                        if selection.tab == tab { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    guard selection.tab == tab else { throw DeveloperChecks.CheckFailure("鼠标点击未切换标签：\(tab.rawValue)") }
                } else { selection.tab = tab }
                // Yield to SwiftUI's scheduled update, then force the actual native layout/display.
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                measurements.append(["cycle": cycle, "tab": tab.rawValue, "milliseconds": elapsed, "hitOffset": [offset.x, offset.y]])
                if !click { try await Task.sleep(for: .milliseconds(150)) }
                if click && cycle == 5 {
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        if let image = bitmap.cgImage { try StyleCompositor.encode(image).write(to: directory.appendingPathComponent("tab-\(tab.rawValue).png")) }
                    }
                }
            }
        }
        guard document.preview === initialPreview, document.contentPreview === initialContent,
              document.style == initialStyle, document.edits == initialEdits, !document.rendering else {
            throw DeveloperChecks.CheckFailure("仅切换标签却重算图片或改变编辑")
        }
        let report: [String: Any] = ["result": click ? "passed" : "measured", "windowPoints": [compact ? 900 : 1120, compact ? 640 : 760], "previewReused": true, "editsUnchanged": true, "inputMode": CommandLine.arguments.contains("--performance-clicks") ? "local-mouse-events" : "binding", "sourcePixels": [3840,2160], "measurements": measurements,
            "scope": "Generated image; local mouse events or binding through native layout/display; no global mouse injection; excludes hardware input latency", "screenCaptureAttempted": false, "generalClipboardModified": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("editor-performance.json"))
    }
}
