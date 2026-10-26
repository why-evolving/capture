import AppKit
import SwiftUI
import CaptureCore

/// Generated control fixture: native menu tracking, bindings, disabled states and paint.
@MainActor enum StudioControlChecks {
    final class Model: ObservableObject {
        @Published var selection = 0
        @Published var enabled = true
        @Published var color = Color.red
        @Published var dark = false
    }
    struct Fixture: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack {
                CaptureChoice("控件回归选项", selection: $model.selection, options: [(0, "适应画布"), (1, "100% 原始像素")]).disabled(!model.enabled)
                CaptureColorWell("控件回归颜色", selection: $model.color)
            }.padding(16).frame(width: 280, height: 100).environment(\.colorScheme, model.dark ? .dark : .light)
        }
    }
    final class Tracking: NSObject, NSMenuDelegate {
        var opened = false
        func menuWillOpen(_ menu: NSMenu) { opened = true }
    }
    static func run(directory: URL) async throws -> [String] {
        func require(_ value: Bool, _ message: String) throws { if !value { throw DeveloperChecks.CheckFailure(message) } }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let model = Model(), host = NSHostingView(rootView: Fixture(model: Model()))
        host.rootView = Fixture(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        guard let choice = descendants(host).compactMap({ $0 as? CapturePopup }).first,
              let well = descendants(host).compactMap({ $0 as? NSColorWell }).first else { throw DeveloperChecks.CheckFailure("共享选择框/颜色控件未生成原生视图") }
        try require(choice.titleOfSelectedItem == "适应画布" && choice.bounds.height >= 28 && choice.bounds.width > 200, "选择框当前值或点击尺寸不正确")
        let tracking = Tracking(); choice.menu?.delegate = tracking
        let dismiss = Timer(timeInterval: 0.2, repeats: false) { _ in MainActor.assumeIsolated { choice.menu?.cancelTracking() } }
        RunLoop.main.add(dismiss, forMode: .common); choice.performClick(nil); dismiss.invalidate()
        try require(tracking.opened, "共享选择框没有打开原生菜单")
        choice.selectItem(at: 1); _ = choice.sendAction(choice.action, to: choice.target)
        try require(model.selection == 1, "选择框没有更新当前绑定")
        model.enabled = false
        try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        choice.selectItem(at: 0); _ = choice.sendAction(choice.action, to: choice.target)
        try require(!choice.isEnabled && model.selection == 1, "禁用选择框仍改变数据")
        model.enabled = true; model.selection = 0
        try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        try require(choice.isEnabled && choice.indexOfSelectedItem == 0, "外部状态变化没有同步选择框")
        well.color = .systemBlue; _ = well.sendAction(well.action, to: well.target)
        try require(NSColor(model.color).isEqual(NSColor.systemBlue), "原生选色没有写回绑定")
        model.dark = true; window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        var labelBrightness: CGFloat = 0
        choice.effectiveAppearance.performAsCurrentDrawingAppearance {
            labelBrightness = NSColor.labelColor.usingColorSpace(.sRGB)?.redComponent ?? 0
        }
        try require(choice.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua && labelBrightness > 0.7,
                    "SwiftUI深色主题没有同步原生选择框，文字对比不足")
        window.appearance = NSAppearance(named: .aqua)
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        surface.appearance = NSAppearance(named: .aqua)
        let secondary = CapturePanelButton(caption: "重选", target: nil, action: nil)
        let primary = CapturePanelButton(caption: "截图并复制", target: nil, action: nil); primary.primary = true
        secondary.frame = CGRect(x: 0, y: 0, width: 90, height: 30); primary.frame = CGRect(x: 100, y: 0, width: 130, height: 30)
        surface.addSubview(secondary); surface.addSubview(primary)
        window.contentView = surface; window.displayIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { throw DeveloperChecks.CheckFailure("共享按钮绘制为空") }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        if let image = bitmap.cgImage { try StyleCompositor.encode(image).write(to: directory.appendingPathComponent("studio-control-buttons.png")) }
        let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
        let sampleY = surface.isFlipped ? Int(10 * scale) : bitmap.pixelsHigh - Int(10 * scale) - 1
        guard let quiet = bitmap.colorAt(x: Int(10 * scale), y: sampleY)?.usingColorSpace(.sRGB),
              let blue = bitmap.colorAt(x: Int(110 * scale), y: sampleY)?.usingColorSpace(.sRGB) else { throw DeveloperChecks.CheckFailure("共享按钮无法取样") }
        try require(min(quiet.redComponent, quiet.greenComponent, quiet.blueComponent) > 0.85 && blue.blueComponent > blue.redComponent + 0.2, "主次按钮绘制混淆：secondary=\(quiet), primary=\(blue), class=\(type(of: secondary)), cell=\(String(describing: secondary.cell))")
        return ["studio-popup-native-menu-tracking", "studio-popup-binding-and-external-update", "studio-popup-disabled-retains-value", "studio-colorwell-native-binding", "studio-button-primary-secondary-pixels", "studio-native-choice-dark-contrast"]
    }
}
