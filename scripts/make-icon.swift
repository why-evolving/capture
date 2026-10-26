import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: Double(pixels) / 1024, y: Double(pixels) / 1024)
        let rect = CGRect(x: 68, y: 68, width: 888, height: 888)
        let shape = CGPath(roundedRect: rect, cornerWidth: 205, cornerHeight: 205, transform: nil)
        context.addPath(shape); context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(srgbRed: 0.70, green: 0.56, blue: 0.93, alpha: 1), CGColor(srgbRed: 0.38, green: 0.30, blue: 0.78, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 930), end: CGPoint(x: 860, y: 90), options: [])
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.96)); context.setLineWidth(47); context.setLineCap(.round)
        for (x, y, dx, dy) in [(300.0, 300.0, 1.0, 1.0), (724, 300, -1, 1), (300, 724, 1, -1), (724, 724, -1, -1)] {
            context.move(to: CGPoint(x: x, y: y + dy * 110)); context.addLine(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + dx * 110, y: y)); context.strokePath()
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.96))
        context.fillEllipse(in: CGRect(x: 480, y: 480, width: 64, height: 64))
        let image = context.makeImage()!
        let representation = NSBitmapImageRep(cgImage: image)
        let data = representation.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
