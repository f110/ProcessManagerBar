import AppKit
import SwiftUI

class LogWindowController {
    static let shared = LogWindowController()

    private var window: NSWindow?
    private var supervisor: ProcessSupervisor?

    func show(supervisor: ProcessSupervisor) {
        self.supervisor = supervisor

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let logView = LogWindowView(supervisor: supervisor)
        let hostingView = NSHostingView(rootView: logView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Process Logs"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LogWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
