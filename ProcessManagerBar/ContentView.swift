import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @State private var importerPresented = false

    var body: some View {
        VStack(spacing: 0) {
            // Config file selector
            HStack {
                if let url = supervisor.configFileURL {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("設定ファイル未選択")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("開く") {
                    importerPresented = true
                }
                .fileImporter(
                    isPresented: $importerPresented,
                    allowedContentTypes: [UTType.yaml, UTType(filenameExtension: "yml") ?? .yaml]
                ) { result in
                    if case .success(let url) = result {
                        supervisor.configFileURL = url
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Process list
            if supervisor.processes.isEmpty {
                Text("プロセスなし")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(supervisor.processes) { proc in
                            ProcessRowView(process: proc)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: CGFloat(supervisor.processes.count) * 36 + 8)
            }

            Divider()

            // Actions
            HStack {
                Button("再起動") {
                    supervisor.restartNeedingRestart()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!supervisor.hasProcessesNeedingRestart)

                Button("再読み込み") {
                    supervisor.loadConfiguration()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Spacer()

                Button("終了") {
                    supervisor.stopAll()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

struct ProcessRowView: View {
    @ObservedObject var process: ManagedProcess

    var body: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(process.config.name)
                .lineLimit(1)
            Spacer()
            Text(stateLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("再起動") { process.restart() }
            Button("停止") { process.stop() }
            Button("開始") { process.start() }
        }
    }

    private var stateColor: Color {
        switch process.state {
        case .stopped: return .red
        case .running: return .green
        case .needsRestart: return .yellow
        }
    }

    private var stateLabel: String {
        switch process.state {
        case .stopped: return "停止"
        case .running: return "実行中"
        case .needsRestart: return "要再起動"
        }
    }
}
