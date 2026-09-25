import AppKit
import SwiftUI

@main
struct MacPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: RuntimeController?
    private var statusBar: StatusBarController?
    private var overlay: NotchOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let runtime = try RuntimeController()
            self.runtime = runtime
            let statusBar = StatusBarController(runtime: runtime)
            self.statusBar = statusBar
            let overlay = NotchOverlayController(runtime: runtime, onOpenDetails: { [weak statusBar] in
                statusBar?.showPopover()
            })
            self.overlay = overlay
            overlay.start()
            Task { await runtime.start() }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "MacPort 无法启动"
            alert.informativeText = IssueFactory.make(for: error).reason + "\n\n" + error.localizedDescription
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
    }
}
