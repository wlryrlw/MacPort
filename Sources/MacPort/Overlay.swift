import AppKit
import SwiftUI

@MainActor
final class NotchOverlayController: NSObject {
    private let runtime: RuntimeController
    private let onOpenDetails: () -> Void
    private var panel: NSPanel?
    private var timer: Timer?
    private var hideDeadline: Date?

    init(runtime: RuntimeController, onOpenDetails: @escaping () -> Void) {
        self.runtime = runtime
        self.onOpenDetails = onOpenDetails
        super.init()
    }

    func start() {
        guard runtime.settings.overlayEnabled else { return }
        let panel = NSPanel(contentRect: notchRect(for: NSScreen.main ?? NSScreen.screens.first),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: SummaryView(runtime: runtime, onOpenDetails: onOpenDetails))
        panel.orderOut(nil)
        self.panel = panel
        timer = Timer.scheduledTimer(timeInterval: 0.1, target: self,
                                     selector: #selector(pollMouse), userInfo: nil, repeats: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func pollMouse() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        let trigger = notchRect(for: screen)
        let inTrigger = trigger.contains(point)
        let inPanel = panel.frame.contains(point)

        if inTrigger || inPanel {
            hideDeadline = nil
            if !panel.isVisible {
                panel.setFrame(trigger, display: true)
                panel.orderFrontRegardless()
            } else if panel.frame != trigger {
                panel.setFrame(trigger, display: true)
            }
        } else if panel.isVisible {
            if hideDeadline == nil { hideDeadline = Date().addingTimeInterval(0.4) }
            if let hideDeadline, Date() >= hideDeadline {
                panel.orderOut(nil)
                self.hideDeadline = nil
            }
        }
    }

    private func notchRect(for screen: NSScreen?) -> NSRect {
        guard let screen else {
            return NSRect(x: 0, y: 0, width: 180, height: 38)
        }
        let frame = screen.frame
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        if let left, let right, !left.isEmpty, !right.isEmpty, right.minX > left.maxX {
            return NSRect(x: left.maxX, y: frame.maxY - 42,
                          width: right.minX - left.maxX, height: 42)
        }
        return NSRect(x: frame.midX - 90, y: frame.maxY - 42, width: 180, height: 42)
    }
}
