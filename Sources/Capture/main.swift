import AppKit
import SwiftUI
import CaptureCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController(store: AppStore())
        self.controller = controller
        controller.start()
        if CommandLine.arguments.contains("--demo") { controller.showStyleEditor() }
        if CommandLine.arguments.contains("--settings") { controller.showSettings() }
        if CommandLine.arguments.contains("--presets") { controller.showPresets() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        Task { guard await controller.recording.confirmTermination() else { sender.reply(toApplicationShouldTerminate: false); return }; await controller.library.flush(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames { controller?.openImage(url: URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }
}

MainActor.assumeIsolated {
 let application = NSApplication.shared
 if let index = CommandLine.arguments.firstIndex(of: "--self-check"), CommandLine.arguments.count > index + 1 {
    application.setActivationPolicy(.accessory)
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    DispatchQueue.global().asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--recording-only") ? 120:60)) {
        let failure = ["result": "failed", "error": "原生自检超时；请检查 interaction-phase.txt。"]
        if let data = try? JSONSerialization.data(withJSONObject: failure, options: .prettyPrinted) {
            try? data.write(to: directory.appendingPathComponent("checks-failure.json"), options: .atomic)
        }
        exit(2)
    }
    Task { @MainActor in
        do { try await DeveloperChecks.run(at: directory); exit(0) }
        catch let error as DeveloperChecks.CheckBlocked {
            let report = ["result": "blocked", "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: directory.appendingPathComponent("checks-blocked.json"), options: .atomic)
            }
            fputs("Self-check blocked: \(error.localizedDescription)\n", stderr); exit(3)
        }
        catch {
            let failure = ["result": "failed", "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: failure, options: .prettyPrinted) {
                try? data.write(to: directory.appendingPathComponent("checks-failure.json"), options: .atomic)
            }
            fputs("Self-check failed: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
    application.run()
 } else {
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
 }
}
