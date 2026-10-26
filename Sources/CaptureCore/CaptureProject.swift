import Foundation
import CoreGraphics

/// Portable, editable local document. Contains the unredacted original; never use as a flattened share image.
public struct CaptureProject: Codable, Equatable, Sendable {
    public static let maximumBytes = 96 * 1024 * 1024
    public var version = 1
    public var id: UUID
    public var createdAt: Date
    public var modifiedAt: Date
    public var name: String
    public var favorite: Bool
    public var originalPNG: Data
    public var style: CaptureStyle
    public var useStyle: Bool
    public var edits: ImageEdits
    public var format: ImageFormat
    public var scale: Double
    public var quality: Double
    public init(id: UUID = UUID(), createdAt: Date = Date(), modifiedAt: Date = Date(), name: String, favorite: Bool = false, originalPNG: Data, style: CaptureStyle, useStyle: Bool, edits: ImageEdits = ImageEdits(), format: ImageFormat = .png, scale: Double = 1, quality: Double = 0.9) {
        self.id = id; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.name = name; self.favorite = favorite
        self.originalPNG = originalPNG; self.style = style; self.useStyle = useStyle; self.edits = edits
        self.format = format; self.scale = scale; self.quality = quality
    }
    public var isValid: Bool {
        version == 1 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200 &&
        createdAt.timeIntervalSince1970.isFinite && modifiedAt.timeIntervalSince1970.isFinite &&
        style.isValid && edits.isValid && [0.5, 1, 2, 3].contains(scale) && quality.isFinite && (0.1...1).contains(quality) &&
        originalPNG.count <= Self.maximumBytes && originalPNG.starts(with: [137,80,78,71,13,10,26,10])
    }
    public func image() throws -> CGImage {
        guard isValid else { throw CaptureFailure.persistence("项目版本或参数无效") }
        return try StyleCompositor.decode(originalPNG)
    }
    public func encoded() throws -> Data {
        _ = try image()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw CaptureFailure.imageTooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CaptureFailure.imageTooLarge }
        let project = try JSONDecoder().decode(Self.self, from: data)
        _ = try project.image()
        return project
    }
    public static func read(_ url: URL) throws -> Self { try decode(BoundedFile.read(url, limit: maximumBytes)) }
    public func write(_ url: URL) throws { try encoded().write(to: url, options: .atomic) }
}

public enum BoundedFile {
    public static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CaptureFailure.imageTooLarge }
        return data
    }
}
