import AppKit
import Combine
import CaptureCore

private actor LibraryWorker {
    let archive: LibraryArchive
    init(directory: URL) { archive = LibraryArchive(directory: directory) }
    func load(days: Int) throws -> [LibraryEntry] { try archive.prune(retentionDays: days) }
    func save(_ project: CaptureProject, days: Int) throws -> [LibraryEntry] { try archive.save(project, retentionDays: days) }
    func thumbnail(_ id: UUID) throws -> Data { try archive.thumbnail(id) }
    func update(_ id: UUID, name: String?, favorite: Bool?, days: Int) throws -> [LibraryEntry] {
        var p = try archive.read(id); if let name { p.name = name }; if let favorite { p.favorite = favorite }; p.modifiedAt = Date()
        return try archive.save(p, retentionDays: days)
    }
    func read(_ id: UUID) throws -> CaptureProject { try archive.read(id) }
    func remove(_ id: UUID) throws -> [LibraryEntry] { try archive.remove(id); return try archive.entries() }
    func clear() throws { try archive.clear() }
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var error: String?
    @Published private(set) var working = false
    private let worker: LibraryWorker
    private var options = HistoryOptions()
    private var generation = 0
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var blockedIDs: Set<UUID> = []
    init(directory: URL) { worker = LibraryWorker(directory: directory) }
    func configure(_ value: HistoryOptions) {
        guard value != options else { return }
        generation += 1; pending.values.forEach { $0.cancel() }; pending.removeAll(); options = value
        reload()
    }
    func reload() {
        let token = generation, days = options.retentionDays
        Task { do { let value = try await worker.load(days: days); if token == generation { entries = value } } catch { self.error = error.localizedDescription } }
    }
    func schedule(_ document: CaptureDocument) {
        guard options.enabled, !document.isSample, !blockedIDs.contains(document.id) else { return }
        pending[document.id]?.cancel()
        let token = generation, days = options.retentionDays, id = document.id
        pending[id] = Task { [weak self, weak document] in
            do {
                try await Task.sleep(for: .milliseconds(450))
                guard let self, let document, !Task.isCancelled else { return }
                let project = try await document.projectSnapshot()
                guard !Task.isCancelled, token == self.generation, self.options.enabled else { return }
                let value = try await self.worker.save(project, days: days)
                if token == self.generation && !Task.isCancelled { self.entries = value; self.error = nil; self.pending[id] = nil }
            } catch is CancellationError {} catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
        }
    }
    func thumbnail(_ id: UUID) async -> NSImage? { guard let data = try? await worker.thumbnail(id) else { return nil }; return NSImage(data: data) }
    func update(_ id: UUID, name: String? = nil, favorite: Bool? = nil) {
        let token = generation, days = options.retentionDays
        Task { do { let result = try await worker.update(id, name: name, favorite: favorite, days: days); if token == generation { entries = result } } catch { self.error = error.localizedDescription } }
    }
    func read(_ id: UUID) async throws -> CaptureProject { try await worker.read(id) }
    func remove(_ id: UUID) {
        blockedIDs.insert(id); pending[id]?.cancel(); pending[id] = nil
        Task { do { entries = try await worker.remove(id) } catch { self.error = error.localizedDescription } }
    }
    func clear() {
        generation += 1; pending.values.forEach { $0.cancel() }; pending.removeAll()
        blockedIDs.formUnion(entries.map(\.id)); working = true
        Task { defer { working = false }; do { try await worker.clear(); entries = []; error = nil } catch { self.error = error.localizedDescription } }
    }
    func flush() async { let tasks = Array(pending.values); for task in tasks { await task.value } }
    func stop() { generation += 1; pending.values.forEach { $0.cancel() }; pending.removeAll() }
}
