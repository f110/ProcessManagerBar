import SwiftUI

@main
struct ProcessManagerBarApp: App {
    @StateObject private var supervisor = ProcessSupervisor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(supervisor: supervisor)
        } label: {
            HStack {
                Image(systemName: menuBarIcon)
            }
        }
        .menuBarExtraStyle(.window)
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
