import AppKit
import CaptureCore

enum SampleImage {
    @MainActor
    static func make(width: Int = 1440, height: Int = 900) -> CGImage {
        let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        NSColor(red: 0.985, green: 0.978, blue: 0.965, alpha: 1).setFill(); bounds.fill()
        let scale = Double(width) / 1440
        func text(_ string: String, x: Double, y: Double, size: Double, color: NSColor, weight: NSFont.Weight = .regular) {
            (string as NSString).draw(at: CGPoint(x: x * scale, y: y * scale), withAttributes: [
                .font: NSFont.systemFont(ofSize: size * scale, weight: weight), .foregroundColor: color
            ])
        }
        let dark = NSColor(red: 0.25, green: 0.24, blue: 0.22, alpha: 1)
        let muted = NSColor(red: 0.55, green: 0.50, blue: 0.44, alpha: 1)
        text("小记", x: 100, y: 725, size: 29, color: dark, weight: .medium)
        text("生活里的小事", x: 1115, y: 730, size: 24, color: muted)
        text("S U N D A Y   J O U R N A L", x: 100, y: 610, size: 23, color: muted)
        text("给生活，留一点空白。", x: 94, y: 460, size: 68, color: dark, weight: .medium)
        text("走一段不赶时间的路，", x: 100, y: 340, size: 28, color: muted)
        text("记下一个突然冒出来的想法。", x: 100, y: 285, size: 28, color: muted)
        NSColor(red: 0.82, green: 0.73, blue: 0.61, alpha: 1).setFill()
        CGRect(x: 100 * scale, y: 220 * scale, width: 80 * scale, height: 4 * scale).fill()
        text("Less, but better.", x: 100, y: 145, size: 24, color: muted)
        for (index, color) in ["C6C4AF", "D9C7A9", "B4C2B2"].enumerated() {
            let rgb = RGBColor(hex: color)
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: (1200 + Double(index) * 27) * scale, y: (143 + Double(index % 2) * 14) * scale,
                                        width: 25 * scale, height: 48 * scale)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return representation.cgImage!
    }
}
