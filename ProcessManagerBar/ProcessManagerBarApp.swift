import SwiftUI
import AppKit

@main
struct ProcessManagerBarApp: App {
    @StateObject private var supervisor = ProcessSupervisor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(supervisor: supervisor)
        } label: {
            menuBarImage
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarImage: some View {
        let symbolName = menuBarIcon
        let color: NSColor = supervisor.hasProcessesNeedingRestart ? .systemYellow : .systemGreen
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        let pointConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let config = paletteConfig.applying(pointConfig)
        let image: NSImage = {
            guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
                return NSImage()
            }
            let configured = base.withSymbolConfiguration(config) ?? base
            configured.isTemplate = false
            return configured
        }()
        return Image(nsImage: image)
    }

    private var menuBarIcon: String {
        if supervisor.hasProcessesNeedingRestart {
            return "exclamationmark.arrow.circlepath"
        } else if supervisor.processes.contains(where: { $0.state == .running }) {
            return "play.circle.fill"
        } else {
            return "play.circle"
        }
    }
}
