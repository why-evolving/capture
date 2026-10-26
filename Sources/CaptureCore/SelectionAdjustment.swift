import CoreGraphics

public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

extension SelectionGeometry {
    public static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        let rect = rect.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return .zero }
        return CGRect(x: min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width),
                      y: min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height),
                      width: rect.width, height: rect.height)
    }

    /// The opposite edges stay fixed; dragging through them stops at the minimum size.
    public static func resized(_ rect: CGRect, handle: SelectionHandle, by delta: CGSize, in bounds: CGRect, minimumSize: Double = 3) -> CGRect {
        let rect = rect.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return .zero }
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        let minimumWidth = min(max(1, minimumSize), rect.width)
        let minimumHeight = min(max(1, minimumSize), rect.height)
        if [.topLeft, .left, .bottomLeft].contains(handle) { left = min(max(left + delta.width, bounds.minX), right - minimumWidth) }
        if [.topRight, .right, .bottomRight].contains(handle) { right = max(min(right + delta.width, bounds.maxX), left + minimumWidth) }
        if [.topLeft, .top, .topRight].contains(handle) { top = min(max(top + delta.height, bounds.minY), bottom - minimumHeight) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(min(bottom + delta.height, bounds.maxY), top + minimumHeight) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
