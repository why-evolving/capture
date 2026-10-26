import AppKit
import CaptureCore

/// Geometric and rendered-ink checks on app-owned controls. No screen or general clipboard access.
@MainActor enum FloatingAlignmentChecks {
    static func run(directory: URL) throws -> [String] {
        func require(_ value: Bool, _ message: String) throws { if !value { throw DeveloperChecks.CheckFailure(message) } }
        let toolbar = SelectionToolbar()
        toolbar.frame = CGRect(x: 0, y: 0, width: 420, height: SelectionToolbar.expandedHeight)
        toolbar.info.stringValue = "1000 × 600 px"
        toolbar.styles.addItem(withTitle: "样式：自定义")
        toolbar.customize.title = ""
        toolbar.inspector.isHidden = false
        toolbar.inspector.apply(SelectionAppearance(style: CaptureStyle(), enabled: true, name: "自定义"))
        let window = SelectionPanel(contentRect: toolbar.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = toolbar; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        toolbar.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let firstRow: [NSView] = [toolbar.info, toolbar.styles, toolbar.customize]
        let secondRow: [NSView] = [toolbar.hint, toolbar.redraw, toolbar.cancel, toolbar.confirm]
        for row in [firstRow, secondRow] {
            try require(row.allSatisfy { abs($0.frame.midY - row[0].frame.midY) < 0.01 && abs($0.frame.height - row[0].frame.height) < 0.01 }, "选区工具条同行控件没有共用中心线/高度")
            for pair in zip(row, row.dropFirst()) { try require(pair.1.frame.minX - pair.0.frame.maxX >= 4, "选区文字和按钮重叠/间距不足") }
        }
        try require(abs(toolbar.info.frame.minX - (toolbar.bounds.maxX - toolbar.confirm.frame.maxX)) < 0.01 && abs(toolbar.customize.frame.maxX - toolbar.confirm.frame.maxX) < 0.01,
                    "选区工具条左右边距或右侧按钮没有对齐")
        try require(abs(toolbar.info.frame.minY - (SelectionToolbar.compactHeight - toolbar.confirm.frame.maxY)) < 0.01, "工具条上下留白不对称")
        guard let rendered = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) else { throw DeveloperChecks.CheckFailure("浮窗像素为空") }
        toolbar.cacheDisplay(in: toolbar.bounds, to: rendered)
        if let image = rendered.cgImage { try StyleCompositor.encode(image).write(to: directory.appendingPathComponent("floating-alignment.png")) }
        var measurements: [[String: Any]] = []
        func ink(_ control: NSView, name: String, color: String, horizontal: Bool = false) throws {
            let bitmap = rendered
            let scale = CGFloat(bitmap.pixelsWide) / toolbar.bounds.width
            let rect = control.convert(control.bounds, to: toolbar)
            let originX = Int((rect.minX * scale).rounded()), originY = Int((rect.minY * scale).rounded())
            let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
            let inset = Int(3 * scale)
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in inset..<(height - inset) {
                for x in inset..<(width - inset) {
                    guard let pixel = bitmap.colorAt(x: originX + x, y: originY + y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.8 else { continue }
                    let r = pixel.redComponent, g = pixel.greenComponent, b = pixel.blueComponent
                    let hit = color == "blue" ? (b - r > 0.25 && b - g > 0.15) :
                              color == "white" ? min(r, g, b) > 0.85 : max(r, g, b) < 0.65
                    if hit { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
                }
            }
            try require(maxX >= minX && maxY >= minY, "浮窗文字/图标为空：" + name)
            let dx = (CGFloat(minX + maxX + 1) / 2 - CGFloat(width) / 2) / scale
            let dy = (CGFloat(minY + maxY + 1) / 2 - CGFloat(height) / 2) / scale
            measurements.append(["name": name, "horizontalOffsetPoints": dx, "verticalOffsetPoints": dy, "backingScale": scale])
            try require(abs(dy) <= 2 && (!horizontal || abs(dx) <= 1.5), "浮窗墨迹没有居中：\(name), dx=\(dx), dy=\(dy)")
        }
        try ink(toolbar.customize, name: "customize-icon", color: "dark", horizontal: true)
        try ink(toolbar.cancel, name: "cancel-icon", color: "dark", horizontal: true)
        try ink(toolbar.redraw, name: "redraw-title", color: "dark", horizontal: true)
        try ink(toolbar.confirm, name: "confirm-title", color: "white", horizontal: true)
        try ink(toolbar.info, name: "size-label", color: "dark")
        try ink(toolbar.hint, name: "hint-label", color: "dark")
        let field = toolbar.inspector.firstColor
        try ink(field, name: "hex-field", color: "dark")
        try require(abs(toolbar.inspector.firstChip.frame.midY - field.frame.midY) < 0.01 && abs(toolbar.inspector.enabled.frame.midY - toolbar.inspector.reset.frame.midY) < 0.01, "颜色块或开关行没有对齐")
        guard let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) else { throw DeveloperChecks.CheckFailure("浮窗快照为空") }
        toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
        if let image = bitmap.cgImage { try StyleCompositor.encode(image).write(to: directory.appendingPathComponent("floating-alignment.png")) }
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw DeveloperChecks.CheckFailure("HEX输入框未获得原生编辑器") }
        let rect = field.convert(editor.bounds, from: editor)
        try require(field.bounds.insetBy(dx: 3, dy: 0).contains(rect) && abs(rect.midY - field.bounds.midY) <= 2, "HEX编辑态没有保持内边距/垂直居中：\(rect)")
        editor.insertText("#123ABC", replacementRange: editor.selectedRange())
        field.validateEditing()
        try require(field.stringValue == "#123ABC", "对齐修正破坏了原生文本录入")
        window.makeFirstResponder(nil)
        let checks = ["floating-toolbar-row-centers-and-margins", "floating-rendered-icons-and-labels-centered", "floating-hex-display-and-editor-alignment"]
        try JSONSerialization.data(withJSONObject: ["result":"passed", "checks":checks, "measurements":measurements, "scope":"Generated AppKit controls, native backing scale, cache-display ink bounds and local field-editor input; excludes hardware mouse and personal screenshots."], options:[.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("floating-alignment.json"))
        return checks
    }
}
