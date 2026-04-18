import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var supervisor: ProcessSupervisor

    var body: some View {
        VStack(spacing: 0) {
            // Config file selector
            HStack {
                if let url = supervisor.configFileURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("設定ファイル未選択")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("開く") {
                    openFileDialog()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            
            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            // Process list
            if supervisor.processes.isEmpty {
                Text("プロセスなし")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 2) {
                    ForEach(supervisor.processes) { proc in
                        ProcessRowView(process: proc)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            // Actions
            HStack(spacing: 8) {
                Button {
                    supervisor.restartNeedingRestart()
                } label: {
                    Text("全て再起動")
                        .font(.system(size: 12))
                }
                .keyboardShortcut("r", modifiers: [.command])
                .controlSize(.small)
                .disabled(!supervisor.hasProcessesNeedingRestart)

                Button {
                    supervisor.loadConfiguration()
                } label: {
                    Text("再読み込み")
                        .font(.system(size: 12))
                }
                .keyboardShortcut("l", modifiers: [.command])
                .controlSize(.small)

                Button {
                    LogWindowController.shared.show(supervisor: supervisor)
                } label: {
                    Text("ログ")
                        .font(.system(size: 12))
                }
                .controlSize(.small)

                Spacer()

                Button {
                    supervisor.stopAll()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("終了")
                        .font(.system(size: 12))
                }
                .keyboardShortcut("q", modifiers: [.command])
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 340)
    }

    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.yaml, UTType(filenameExtension: "yml") ?? .yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = .floating
        if panel.runModal() == .OK, let url = panel.url {
            supervisor.configFileURL = url
        }
    }
}

struct ProcessRowView: View {
    @ObservedObject var process: ManagedProcess
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(process.config.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            if case .error(let message) = process.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))
                    .help(message)
            } else {
                Image(systemName: stateIcon)
                    .foregroundColor(stateColor)
                    .font(.system(size: 13))
                    .help(stateTooltip)
            }
            Button {
                process.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(process.state == .stopped || process.state.isError)
            .help("再起動")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
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
        case .error: return .orange
        }
    }

    private var stateIcon: String {
        switch process.state {
        case .stopped: return "stop.circle.fill"
        case .running: return "checkmark.circle.fill"
        case .needsRestart: return "arrow.clockwise.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var stateTooltip: String {
        switch process.state {
        case .stopped: return "停止"
        case .running: return "実行中"
        case .needsRestart: return "要再起動"
        case .error(let msg): return msg
        }
    }
}
