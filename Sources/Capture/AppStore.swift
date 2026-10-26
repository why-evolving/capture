import AppKit
import CaptureCore
import Combine
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var preferences: AppPreferences
    @Published var errorMessage: String?
    @Published var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published var recordingShortcutError: String?
    @Published var shortcutError: String?
    private let url: URL
    private var pendingSave: DispatchWorkItem?
    private var corruptFile = false
    var presets: [StylePreset] { StylePreset.builtIns + preferences.customPresets }
    var activeName: String { presets.first(where: { $0.style == preferences.activeStyle })?.name ?? "自定义" }
    var defaultPreset: StylePreset? { presets.first { $0.id == preferences.defaultPresetID } }
    var captureStyle: CaptureStyle { defaultPreset?.style ?? preferences.activeStyle }
    var defaultName: String { defaultPreset?.name ?? activeName }
    var onChange: (() -> Void)?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Capture/preferences.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { preferences = try PreferencesIO.load(from: self.url) }
            catch { preferences = AppPreferences(); errorMessage = "已使用默认设置，原设置文件会在下次保存前备份。"; corruptFile = true }
        } else { preferences = AppPreferences() }
        // Migrate the existing capture style to an explicit default without losing it.
        if preferences.defaultPresetID == nil {
            if let preset = presets.first(where: { $0.style == preferences.activeStyle }) {
                preferences.defaultPresetID = preset.id
            } else if preferences.customPresets.count < 100 {
                var name = "原有默认样式"
                while presets.contains(where: { $0.name == name }) { name += " 副本" }
                let preset = StylePreset(name: String(name.prefix(40)), style: preferences.activeStyle)
                preferences.customPresets.append(preset); preferences.defaultPresetID = preset.id
            }
        }
    }
    func update(_ body: (inout AppPreferences) -> Void) {
        var next = preferences
        body(&next)
        guard next != preferences else { return }
        guard next.isValid else { errorMessage = "设置参数无效，未应用这次更改。"; return }
        preferences = next
        onChange?()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        do {
            if corruptFile, FileManager.default.fileExists(atPath: url.path) {
                let backup = url.deletingLastPathComponent().appendingPathComponent("preferences-backup-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: backup)
                corruptFile = false
            }
            try PreferencesIO.save(preferences, to: url)
        } catch { errorMessage = error.localizedDescription }
    }
    func useStyle(_ style: CaptureStyle) { update { $0.activeStyle = style } }
    @discardableResult
    func savePreset(name: String, style: CaptureStyle, makeDefault: Bool = false) -> String? {
        guard style.isValid else { errorMessage = "样式参数无效，未保存预设。"; return nil }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard validPresetName(trimmed) else { return nil }
        if preferences.customPresets.count >= 100 { errorMessage = "最多保存 100 套自定义预设。"; return nil }
        let preset = StylePreset(name: trimmed, style: style)
        update { $0.customPresets.append(preset); if makeDefault { $0.defaultPresetID = preset.id } }
        errorMessage = nil
        return preset.id
    }
    func setDefaultPreset(_ id: String) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        update { $0.defaultPresetID = id; $0.activeStyle = preset.style }
        errorMessage = nil
    }
    func renamePreset(_ id: String, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard let index = preferences.customPresets.firstIndex(where: { $0.id == id }), validPresetName(trimmed, excluding: id) else { return }
        update { $0.customPresets[index].name = trimmed }; errorMessage = nil
    }
    func updatePreset(_ id: String, style: CaptureStyle) {
        guard let index = preferences.customPresets.firstIndex(where: { $0.id == id }), style.isValid else { return }
        update { $0.customPresets[index].style = style }; errorMessage = nil
    }
    func deletePreset(_ id: String) {
        guard preferences.customPresets.contains(where: { $0.id == id }) else { return }
        update {
            $0.customPresets.removeAll { $0.id == id }
            if $0.defaultPresetID == id { $0.defaultPresetID = StylePreset.builtIns[0].id }
        }
        errorMessage = nil
    }
    private func validPresetName(_ name: String, excluding id: String? = nil) -> Bool {
        guard !name.isEmpty else { errorMessage = "请输入预设名称。"; return false }
        guard !presets.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "已经有同名预设，请换一个名称。"; return false
        }
        return true
    }
    func refreshPermission() { permissionGranted = CGPreflightScreenCaptureAccess() }
    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermission()
    }
    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

extension CaptureCore.RGBColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
    init(_ color: Color) {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent)
    }
}

enum CaptureTheme {
    static let accentNS = NSColor(srgbRed: 0.196, green: 0.404, blue: 0.910, alpha: 1)
    static let accent = Color(nsColor: accentNS)
    static let secondaryAccent = Color(red: 0.31, green: 0.69, blue: 0.86)
    static let brand = LinearGradient(colors: [accent, secondaryAccent], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let border = Color.primary.opacity(0.07)
    static let canvasNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.07, green: 0.085, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.949, green: 0.957, blue: 0.973, alpha: 1)
    }
    static let canvas = Color(nsColor: canvasNS)
    static let chromeNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.115, green: 0.13, blue: 0.16, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.984, blue: 0.992, alpha: 1)
    }
    static let chrome = Color(nsColor: chromeNS)
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.14, green: 0.16, blue: 0.20, alpha: 1) : .white
    })
}

private typealias ControlHoverState<Value> = SwiftUI.State<Value>

struct CaptureActionStyle: ButtonStyle {
    var primary = false
    var destructive = false
    private var actionColor: Color { destructive ? .red : CaptureTheme.accent }
    @Environment(\.isEnabled) private var enabled
    @ControlHoverState private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10).frame(minHeight: 30)
            .foregroundStyle(primary ? .white : Color.primary.opacity(0.85))
            .background(primary ? actionColor : (hovered ? CaptureTheme.canvas : CaptureTheme.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? actionColor : CaptureTheme.border, lineWidth: 1))
            .contentShape(Rectangle()).opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
            .onHover { hovered = $0 }
    }
}
