import AppKit
import CaptureCore

enum ClipboardService {
    @MainActor
    static func write(_ image: CGImage, to pasteboard: NSPasteboard = .general) throws {
        // Encode first: a failed render/encode must not erase the previous clipboard.
        let png = try StyleCompositor.encode(image)
        let rep = NSBitmapImageRep(cgImage: image)
        let tiff = rep.representation(using: .tiff, properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)])
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CaptureFailure.clipboard }
    }
}
