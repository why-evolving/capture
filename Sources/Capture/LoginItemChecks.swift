import AppKit
import SwiftUI

@MainActor enum LoginItemChecks {
    final class Service: LoginItemServicing {
        var current: LoginItemStatus = .notRegistered
        var next: LoginItemStatus = .enabled
        var fail = false
        var delay = false
        var calls: [Bool] = []
        var settingsOpened = false
        func status() -> LoginItemStatus { current }
        func setEnabled(_ enabled: Bool) async throws {
            calls.append(enabled)
            if delay { try await Task.sleep(for: .milliseconds(40)) }
            if fail { throw NSError(domain: "CaptureLoginItemTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统拒绝更改"]) }
            current = enabled ? next : .notRegistered
        }
        func openSettings() { settingsOpened = true }
    }
    static func run(directory: URL) async throws -> [String] {
        func require(_ value: Bool, _ message: String) throws { if !value { throw DeveloperChecks.CheckFailure(message) } }
        var checks: [String] = []
        let service = Service(), controller: LoginItemController
        controller = LoginItemController(service: service)
        try require(!controller.status.requested && service.calls.isEmpty, "启动时自动注册了登录项")
        await controller.setEnabled(true)
        try require(controller.status == .enabled && controller.errorText == nil, "注册成功未反映真实状态")
        await controller.setEnabled(false)
        try require(controller.status == .notRegistered && service.calls == [true, false], "关闭未注销")
        checks.append("login-default-off-enable-disable-readback")

        service.next = .requiresApproval
        await controller.setEnabled(true)
        try require(controller.status == .requiresApproval && controller.status.requested && controller.errorText == nil, "待批准被错误显示为已成功或关闭")
        controller.openSettings(); try require(service.settingsOpened, "登录项设置入口无效")
        try await DeveloperChecks.snapshot(LoginItemSettingsView(controller: controller), name: "login-pending-light.png", width: 510, height: 200, appearance: .light, directory: directory)
        await controller.setEnabled(false)
        try require(controller.status == .notRegistered, "待批准无法取消")
        checks.append("login-pending-guidance-and-cancel")

        service.fail = true
        await controller.setEnabled(true)
        try require(!controller.status.requested && controller.errorText != nil && !controller.isUpdating, "注册失败伪装成功或阻止重试")
        try await DeveloperChecks.snapshot(LoginItemSettingsView(controller: controller), name: "login-error-dark.png", width: 510, height: 240, appearance: .dark, directory: directory)
        service.current = .enabled; controller.refresh()
        await controller.setEnabled(false)
        try require(controller.status == .enabled && controller.errorText != nil, "注销失败却显示关闭")
        service.fail = false; await controller.setEnabled(false)
        try require(controller.status == .notRegistered && controller.errorText == nil, "失败后无法重试")
        checks.append("login-failures-keep-system-state-and-retry")

        service.current = .enabled; controller.refresh()
        let count = service.calls.count
        service.current = .requiresApproval; controller.refresh()
        try require(controller.status == .requiresApproval && service.calls.count == count, "外部撤销未同步或被擅自重新注册")
        service.current = .notFound; controller.refresh()
        try require(!controller.status.requested && controller.status == .notFound, "缺失服务仍显示开启")
        service.next = .enabled; await controller.setEnabled(true)
        try require(controller.status == .enabled, "首次未找到记录时无法开启注册")
        checks.append("login-external-change-refresh-no-reregister")

        service.current = .notRegistered; service.next = .notRegistered; controller.refresh()
        await controller.setEnabled(true)
        try require(controller.errorText != nil && !controller.status.requested, "API无错但状态未更改却显示成功")
        checks.append("login-api-success-requires-state-change")

        service.next = .enabled; service.delay = true
        let countBefore = service.calls.count
        let first = Task { await controller.setEnabled(true) }
        while !controller.isUpdating { await Task.yield() }
        await controller.setEnabled(false); controller.refresh()
        await first.value
        try require(service.calls.count == countBefore + 1 && controller.status == .enabled && !controller.isUpdating, "连续请求发生重入或状态被旧任务覆盖")
        checks.append("login-busy-rejects-duplicate-request")
        try await DeveloperChecks.snapshot(LoginItemSettingsView(controller: controller), name: "login-enabled-light.png", width: 510, height: 180, appearance: .light, directory: directory)
        service.current = .notRegistered; controller.refresh()
        try await DeveloperChecks.snapshot(LoginItemSettingsView(controller: controller), name: "login-disabled-dark.png", width: 510, height: 180, appearance: .dark, directory: directory)
        checks.append("login-light-dark-state-layouts")
        return checks
    }

    /// Explicit integration check, only for the installed daily app; restores the original state.
    static func checkSystem(directory: URL) async throws {
        guard let path = ProcessInfo.processInfo.environment["CAPTURE_INSTALLED_APP"],
              path.hasPrefix("/"), path.hasSuffix("/Capture.app") else {
            throw DeveloperChecks.CheckBlocked("请用 CAPTURE_INSTALLED_APP 明确指定已安装的应用绝对路径。")
        }
        let expected = URL(fileURLWithPath: path).standardizedFileURL
        guard Bundle.main.bundleURL.standardizedFileURL == expected else {
            throw DeveloperChecks.CheckBlocked("真实登录项测试只能从日常应用路径执行，避免注册临时构建。")
        }
        let service = SystemLoginItemService()
        let original = service.status()
        var states = [original.rawValue]
        // Apple's framework can return notFound before this app's first registration.
        guard original == .notRegistered || original == .notFound else {
            throw DeveloperChecks.CheckBlocked("已有登录项状态为\(original.rawValue)，保留用户设置，未执行往返。")
        }
        var capturedError: Error?
        do {
            try await service.setEnabled(true)
            states.append(service.status().rawValue)
            guard service.status() == .enabled else { throw DeveloperChecks.CheckBlocked("系统登录项需要用户批准，未验证为可启动。") }
        } catch { capturedError = error }
        // Even a failed registration may create a pending entry. Always clean up this test's registration.
        if service.status().requested { try await service.setEnabled(false) }
        let restored = !service.status().requested
        states.append(service.status().rawValue)
        let report: [String: Any] = ["result": capturedError == nil && restored ? "passed" : "not-passed", "states": states,
            "restoredOriginal": restored, "bundlePath": expected.path, "physicalLoginTested": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("login-system.json"))
        if let capturedError { throw capturedError }
        guard restored else { throw DeveloperChecks.CheckFailure("登录项未恢复原状态，请在系统登录项检查 Capture。") }
    }
}
