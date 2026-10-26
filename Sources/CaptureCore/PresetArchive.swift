import Foundation

public struct PresetArchive: Codable, Sendable {
    public static let maximumBytes = 1024 * 1024
    public var version = 1
    public var presets: [StylePreset]
    public init(presets: [StylePreset]) { self.presets = presets }
    private var valid: Bool {
        version == 1 && !presets.isEmpty && presets.count <= 100 && presets.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 && $0.style.isValid
        }
    }
    public func encoded() throws -> Data {
        guard valid else { throw CaptureFailure.persistence("预设包包含无效内容") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CaptureFailure.imageTooLarge }
        return data
    }
    /// Validate the entire archive before returning anything; imports never preserve external IDs.
    public static func imported(_ data: Data, existing: [StylePreset]) throws -> [StylePreset] {
        guard data.count <= maximumBytes else { throw CaptureFailure.imageTooLarge }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.valid, existing.filter({ !$0.isBuiltIn }).count + archive.presets.count <= 100 else {
            throw CaptureFailure.persistence("预设包无效，或导入后超过 100 个自定义预设")
        }
        var names = Set(existing.map { $0.name.lowercased() })
        return archive.presets.map { item in
            let base = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = base, suffix = 2
            while names.contains(name.lowercased()) {
                let tail = " (\(suffix))"; name = String(base.prefix(40 - tail.count)) + tail; suffix += 1
            }
            names.insert(name.lowercased())
            return StylePreset(name: name, style: item.style)
        }
    }
}
