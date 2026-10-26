import Foundation

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyLabel: String
    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    // Carbon commandKey | shiftKey. This does not alter the system screenshot shortcuts.
    public static let defaultCapture = Shortcut(keyCode: 19, modifiers: (1 << 8) | (1 << 9), keyLabel: "2")
    public var display: String {
        ((modifiers & (1 << 12)) != 0 ? "⌃" : "") +
        ((modifiers & (1 << 11)) != 0 ? "⌥" : "") +
        ((modifiers & (1 << 9)) != 0 ? "⇧" : "") +
        ((modifiers & (1 << 8)) != 0 ? "⌘" : "") + keyLabel
    }
    public var isValid: Bool {
        let allowedModifiers: UInt32 = (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)
        let requiredModifiers: UInt32 = (1 << 8) | (1 << 11) | (1 << 12)
        guard keyCode <= 127, !keyLabel.isEmpty, keyLabel.count <= 16 else { return false }
        return modifiers & ~allowedModifiers == 0 && modifiers & requiredModifiers != 0
    }
}

public struct CaptureOptions: Codable, Equatable, Sendable {
    public var delay = 0
    public var includeCursor = false
    // Optional for settings written before adjustable selection was introduced.
    public var adjustBeforeCapture: Bool? = nil
    // Older nil values now resolve to the adjustable workflow; explicit quick mode is preserved.
    public var allowsSelectionAdjustment: Bool { adjustBeforeCapture ?? true }
    public init() {}
    public var isValid: Bool { [0, 3, 5, 10].contains(delay) }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var automaticStyle = true
    public var activeStyle = CaptureStyle()
    public var customPresets: [StylePreset] = []
    public var shortcut = Shortcut.defaultCapture
    public var showThumbnail = true
    public var hasLaunched = false
    public var saveDirectory: String? = nil
    public var captureOptions: CaptureOptions? = nil
    public var defaultPresetID: String? = nil
    public var presentation: PresentationOptions? = nil
    public var localHistory: HistoryOptions? = nil
    public var recording: RecordingOptions? = nil
    public init() {}
    public var isValid: Bool { PreferencesIO.valid(self) }
}

public enum PreferencesIO {
    public static func load(from url: URL) throws -> AppPreferences {
        let value = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
        guard valid(value) else { throw CaptureFailure.persistence("设置文件包含无效参数") }
        return value
    }
    public static func valid(_ value: AppPreferences) -> Bool {
        (value.recording?.isValid ?? true) && (value.recording == nil || !value.recording!.shortcut.hasSameKeys(as: value.shortcut)) && (value.presentation?.isValid ?? true) && (value.localHistory?.isValid ?? true) && value.version == 1 && value.activeStyle.isValid && value.shortcut.isValid && (value.captureOptions?.isValid ?? true) &&
        (value.defaultPresetID == nil || (StylePreset.builtIns + value.customPresets).contains(where: { $0.id == value.defaultPresetID })) &&
        value.customPresets.count <= 100 &&
        Set(value.customPresets.map(\.id)).count == value.customPresets.count &&
        value.customPresets.allSatisfy { preset in
            !preset.id.isEmpty && !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preset.name.count <= 40 &&
            !preset.isBuiltIn && preset.style.isValid && !StylePreset.builtIns.contains(where: { $0.id == preset.id })
        }
    }
    public static func save(_ preferences: AppPreferences, to url: URL) throws {
        guard valid(preferences) else { throw CaptureFailure.persistence("不能保存无效设置") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
    }
}
