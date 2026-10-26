import AppKit
import ServiceManagement
import SwiftUI

enum LoginItemStatus: String {
    case notRegistered, enabled, requiresApproval, notFound

    var requested: Bool { self == .enabled || self == .requiresApproval }
    var message: String {
        switch self {
        case .notRegistered: return "未开启。开启后，登录 Mac 时 Capture 会自动出现在菜单栏。"
        case .enabled: return "已开启。下次登录 Mac 时自动启动，保持菜单栏待命。"
        case .requiresApproval: return "等待系统批准。请在系统设置的登录项中允许 Capture。"
        case .notFound: return "尚未开启。开启后，登录 Mac 时 Capture 会自动出现在菜单栏。"
        }
    }
}

@MainActor protocol LoginItemServicing {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) async throws
    func openSettings()
}

struct SystemLoginItemService: LoginItemServicing {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        // Service registration can involve IPC/disk work; keep it off the UI thread.
        try await Task.detached(priority: .userInitiated) { try Self.change(enabled) }.value
    }
    nonisolated private static func change(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var isUpdating = false
    @Published private(set) var errorText: String?
    private let service: any LoginItemServicing

    init(service: (any LoginItemServicing)? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status()
    }
    func refresh() {
        guard !isUpdating else { return }
        let updated = service.status()
        if updated != status { errorText = nil }
        status = updated
    }
    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true; errorText = nil
        defer { isUpdating = false }
        do {
            // Read back the system state, including changes made outside Capture.
            status = service.status()
            if enabled != status.requested { try await service.setEnabled(enabled) }
            status = service.status()
            if enabled != status.requested { errorText = "系统尚未完成更改，请重试或打开登录项检查。" }
        } catch {
            status = service.status()
            if !(enabled && status.requested) {
                errorText = "无法\(enabled ? "开启" : "关闭")登录时启动：\(error.localizedDescription)"
            }
        }
    }
    func openSettings() { service.openSettings() }
}

struct LoginItemSettingsView: View {
    @ObservedObject var controller: LoginItemController
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("启动与常驻").font(.headline)
                Toggle("登录时启动", isOn: Binding(get: { controller.status.requested }, set: { enabled in
                    Task { await controller.setEnabled(enabled) }
                }))
                .disabled(controller.isUpdating)
                .accessibilityIdentifier("login-at-launch")
                HStack(alignment: .top, spacing: 7) {
                    if controller.isUpdating { ProgressView().controlSize(.small) }
                    else { Image(systemName: controller.status == .enabled ? "checkmark.circle" : controller.status == .requiresApproval ? "clock" : "info.circle") }
                    Text(controller.isUpdating ? "正在更新登录项…" : controller.status.message)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.caption).foregroundStyle(controller.status == .requiresApproval ? Color.orange : .secondary)
                if let error = controller.errorText { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if controller.status == .requiresApproval || controller.errorText != nil {
                    HStack {
                        Button("打开系统登录项") { controller.openSettings() }
                        Button("刷新状态") { controller.refresh() }.disabled(controller.isUpdating)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { controller.refresh() }
    }
}
