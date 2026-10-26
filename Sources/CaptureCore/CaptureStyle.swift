import Foundation
import CoreGraphics

public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case gradient, aurora, solid, transparent
    public var label: String {
        switch self { case .aurora: return "极光"; case .gradient: return "渐变"; case .solid: return "纯色"; case .transparent: return "透明" }
    }
}

public enum CanvasRatio: String, Codable, CaseIterable, Sendable {
    case automatic, square, standard, wide, portrait, story
    public var label: String {
        switch self { case .portrait: return "4 : 5"; case .story: return "9 : 16"; case .automatic: return "自适应"; case .square: return "1 : 1"; case .standard: return "4 : 3"; case .wide: return "16 : 9" }
    }
    public var value: Double? {
        switch self { case .portrait: return 4 / 5; case .story: return 9 / 16; case .automatic: return nil; case .square: return 1; case .standard: return 4 / 3; case .wide: return 16 / 9 }
    }
}

public enum VerticalPosition: String, Codable, CaseIterable, Sendable {
    case top, center, bottom
    public var symbol: String {
        switch self { case .top: return "align.vertical.top"; case .center: return "align.vertical.center"; case .bottom: return "align.vertical.bottom" }
    }
    public var label: String {
        switch self { case .top: return "靠上"; case .center: return "居中"; case .bottom: return "靠下" }
    }
}

public enum WindowAppearance: String, Codable, CaseIterable, Sendable {
    case light, dark
    public var label: String { self == .light ? "浅色" : "深色" }
}

public struct RGBColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    public init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }
    public var hex: String {
        String(format: "%02X%02X%02X", Int(clamped(red) * 255), Int(clamped(green) * 255), Int(clamped(blue) * 255))
    }
    public var cgColor: CGColor { CGColor(srgbRed: clamped(red), green: clamped(green), blue: clamped(blue), alpha: 1) }
    public var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    private func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

public struct CaptureStyle: Codable, Equatable, Sendable {
    public var background: BackgroundKind = .gradient
    public var firstColor = RGBColor(hex: "A494ED")
    public var secondColor = RGBColor(hex: "F2B9B5")
    public var angle: Double = 135
    public var padding: Double = 96
    public var radius: Double = 16
    public var shadow: Double = 40
    public var softness: Double = 64
    public var imageScale: Double = 100
    public var ratio: CanvasRatio = .automatic
    public var position: VerticalPosition = .center
    public var grain = false
    public var border = false
    public var windowFrame = false
    public var windowAppearance: WindowAppearance = .light
    public var windowTitle = ""
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case background, firstColor, secondColor, angle, padding, radius, shadow, softness, imageScale, ratio, position, grain, border, windowFrame, windowAppearance, windowTitle
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        background = try values.decodeIfPresent(BackgroundKind.self, forKey: .background) ?? background
        firstColor = try values.decodeIfPresent(RGBColor.self, forKey: .firstColor) ?? firstColor
        secondColor = try values.decodeIfPresent(RGBColor.self, forKey: .secondColor) ?? secondColor
        angle = try values.decodeIfPresent(Double.self, forKey: .angle) ?? angle
        padding = try values.decodeIfPresent(Double.self, forKey: .padding) ?? padding
        radius = try values.decodeIfPresent(Double.self, forKey: .radius) ?? radius
        shadow = try values.decodeIfPresent(Double.self, forKey: .shadow) ?? shadow
        softness = try values.decodeIfPresent(Double.self, forKey: .softness) ?? softness
        imageScale = try values.decodeIfPresent(Double.self, forKey: .imageScale) ?? imageScale
        ratio = try values.decodeIfPresent(CanvasRatio.self, forKey: .ratio) ?? ratio
        position = try values.decodeIfPresent(VerticalPosition.self, forKey: .position) ?? position
        grain = try values.decodeIfPresent(Bool.self, forKey: .grain) ?? grain
        border = try values.decodeIfPresent(Bool.self, forKey: .border) ?? border
        windowFrame = try values.decodeIfPresent(Bool.self, forKey: .windowFrame) ?? windowFrame
        windowAppearance = try values.decodeIfPresent(WindowAppearance.self, forKey: .windowAppearance) ?? .light
        windowTitle = try values.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
    }
    public var isValid: Bool {
        firstColor.isValid && secondColor.isValid &&
        Self.valid(angle, 0...360) && Self.valid(padding, 0...240) &&
        Self.valid(radius, 0...48) && Self.valid(shadow, 0...100) &&
        Self.valid(softness, 0...100) && Self.valid(imageScale, 60...100) && windowTitle.count <= 120
    }
    private static func valid(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
}

public struct StylePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var style: CaptureStyle
    public var isBuiltIn: Bool
    public init(id: String = UUID().uuidString, name: String, style: CaptureStyle, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.style = style; self.isBuiltIn = isBuiltIn
    }
    public static let builtIns: [StylePreset] = {
        func make(_ id: String, _ name: String, _ colors: [String], _ padding: Double, _ radius: Double, _ shadow: Double) -> StylePreset {
            var style = CaptureStyle()
            style.firstColor = RGBColor(hex: colors[0]); style.secondColor = RGBColor(hex: colors[1])
            style.padding = padding; style.radius = radius; style.shadow = shadow
            if id == "paper" { style.background = .solid }
            return StylePreset(id: id, name: name, style: style, isBuiltIn: true)
        }
        var lightWindow = make("mac-light", "浅色窗口", ["B4C6DF", "EAD9DB"], 96, 16, 40)
        lightWindow.style.windowFrame = true; lightWindow.style.windowAppearance = .light
        var darkWindow = make("mac-dark", "深色窗口", ["ADB2D7", "E8C7CB"], 96, 16, 48)
        darkWindow.style.windowFrame = true; darkWindow.style.windowAppearance = .dark
        let auroras = [("aurora", "极光", "55D6BE", "7771E5"), ("bloom", "花雾", "EF94BB", "AA99EA"), ("tide", "潮汐", "539AE5", "82DEC9"), ("ember", "余晖", "F3BC76", "D46E96")].map { id, name, a, b in
            var preset = make(id, name, [a, b], 112, 20, 36); preset.style.background = .aurora; return preset
        }
        return [
            make("dusk", "暮光", ["A494ED", "F2B9B5"], 96, 16, 40),
            lightWindow, darkWindow,
            make("salt", "海盐", ["9CC4CC", "E0E9DE"], 112, 12, 28),
            make("apricot", "杏桃", ["EDAA90", "F4D9B5"], 96, 20, 34),
            make("moss", "青苔", ["9CAE9E", "DBE0C5"], 120, 12, 30),
            make("graphite", "石墨", ["393943", "77727F"], 112, 10, 65),
            make("paper", "留白", ["E9E4DC", "E9E4DC"], 120, 4, 22)
        ] + auroras
    }()
}

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png = "PNG", jpeg = "JPEG"
    public var fileExtension: String { self == .png ? "png" : "jpg" }
}

public enum CaptureFailure: LocalizedError {
    case invalidStyle, invalidImage, imageTooLarge, encoding, clipboard, permission, displayUnavailable, shortcutInUse, persistence(String)
    public var errorDescription: String? {
        switch self {
        case .invalidStyle: return "这套样式包含无效参数，请重新选择预设。"
        case .invalidImage: return "无法读取这张图片。"
        case .imageTooLarge: return "输出尺寸过大，请降低输出倍率或缩小画布。"
        case .encoding: return "图片编码失败，剪贴板和已有文件没有改变。"
        case .clipboard: return "无法写入剪贴板，请重新复制。"
        case .permission: return "需要在系统设置中允许 Capture 录制屏幕，然后重新尝试截图。"
        case .displayUnavailable: return "显示器已断开，请重新框选截图。"
        case .shortcutInUse: return "这个快捷键已被占用，请换一个组合。"
        case .persistence(let reason): return "设置保存失败：\(reason)"
        }
    }
}
