import Foundation
import CoreGraphics

public enum ThumbnailCorner: String, Codable, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft
    public var label: String { switch self { case .bottomRight: return "右下"; case .bottomLeft: return "左下"; case .topRight: return "右上"; case .topLeft: return "左上" } }
    public func origin(in screen: CGRect, size: CGSize, margin: Double = 22) -> CGPoint {
        let left = self == .bottomLeft || self == .topLeft
        let top = self == .topLeft || self == .topRight
        return CGPoint(x: left ? screen.minX + margin : max(screen.minX, screen.maxX - size.width - margin),
                       y: top ? max(screen.minY, screen.maxY - size.height - margin) : screen.minY + margin)
    }
}
public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var label: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
}
public struct PresentationOptions: Codable, Equatable, Sendable {
    public var corner: ThumbnailCorner = .bottomRight
    public var thumbnailSeconds = 6
    public var theme: AppTheme = .light
    public var reduceMotion = false
    public init() {}
    public var isValid: Bool { [0,3,6,10].contains(thumbnailSeconds) }
}
public struct HistoryOptions: Codable, Equatable, Sendable {
    public var enabled = false
    public var retentionDays = 7
    public init() {}
    public var isValid: Bool { [7,30].contains(retentionDays) }
}
public enum ViewportGeometry {
    public static func pointSize(pixels: CGSize, zoom: Double, backingScale: Double) -> CGSize {
        guard zoom.isFinite, zoom > 0, backingScale.isFinite, backingScale > 0 else { return .zero }
        return CGSize(width: pixels.width * zoom / backingScale, height: pixels.height * zoom / backingScale)
    }
}
