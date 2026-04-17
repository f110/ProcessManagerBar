import SwiftUI
import AppKit

struct LogWindowView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @State private var selectedProcessId: String?
    @State private var searchText: String = ""
    @State private var isSearchVisible = false
    @State private var searchMatchIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if supervisor.processes.isEmpty {
                Text("プロセスなし")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Tab bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(supervisor.processes) { proc in
                            TabButton(
                                title: proc.config.name,
                                isSelected: selectedProcessId == proc.id
                            ) {
                                selectedProcessId = proc.id
                                searchText = ""
                                searchMatchIndex = 0
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.top, 8)

                Divider()

                // Search bar
                if isSearchVisible {
                    SearchBarView(
                        searchText: $searchText,
                        matchIndex: $searchMatchIndex,
                        totalMatches: currentMatchCount,
                        onClose: {
                            isSearchVisible = false
                            searchText = ""
                            searchMatchIndex = 0
                        }
                    )
                    Divider()
                }

                // Log content
                if let proc = selectedProcess {
                    LogContentView(
                        logOutput: proc.logOutput,
                        searchText: searchText,
                        searchMatchIndex: searchMatchIndex
                    )
                } else {
                    Text("タブを選択してください")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .onAppear {
            if selectedProcessId == nil {
                selectedProcessId = supervisor.processes.first?.id
            }
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
                    isSearchVisible = true
                    return nil
                }
                return event
            }
        }
    }

    private var selectedProcess: ManagedProcess? {
        supervisor.processes.first { $0.id == selectedProcessId }
    }

    private var currentMatchCount: Int {
        guard let proc = selectedProcess, !searchText.isEmpty else { return 0 }
        return proc.logOutput.countOccurrences(of: searchText)
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct SearchBarView: View {
    @Binding var searchText: String
    @Binding var matchIndex: Int
    let totalMatches: Int
    let onClose: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("検索...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isTextFieldFocused)
                .onAppear {
                    isTextFieldFocused = true
                }
                .onChange(of: searchText) {
                    matchIndex = 0
                }

            if !searchText.isEmpty {
                Text("\(totalMatches > 0 ? matchIndex + 1 : 0)/\(totalMatches)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Button {
                    if totalMatches > 0 {
                        matchIndex = (matchIndex - 1 + totalMatches) % totalMatches
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(totalMatches == 0)

                Button {
                    if totalMatches > 0 {
                        matchIndex = (matchIndex + 1) % totalMatches
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(totalMatches == 0)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct LogContentView: View {
    let logOutput: String
    let searchText: String
    let searchMatchIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lines = logOutput.components(separatedBy: "\n")
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        LogLineView(
                            line: line,
                            lineNumber: index + 1,
                            searchText: searchText,
                            isCurrentMatch: isLineCurrentMatch(lineIndex: index)
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .font(.system(size: 12, design: .monospaced))
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logOutput) {
                // Auto-scroll to bottom when new output arrives
                let lineCount = logOutput.components(separatedBy: "\n").count
                if lineCount > 0 && searchText.isEmpty {
                    proxy.scrollTo(lineCount - 1, anchor: .bottom)
                }
            }
            .onChange(of: searchMatchIndex) {
                scrollToMatch(proxy: proxy)
            }
            .onChange(of: searchText) {
                if !searchText.isEmpty {
                    scrollToMatch(proxy: proxy)
                }
            }
        }
    }

    private func scrollToMatch(proxy: ScrollViewProxy) {
        guard !searchText.isEmpty else { return }
        let lines = logOutput.components(separatedBy: "\n")
        let searchLower = searchText.lowercased()
        var matchCount = 0
        for (index, line) in lines.enumerated() {
            let lineLower = line.lowercased()
            var searchStart = lineLower.startIndex
            while let range = lineLower.range(of: searchLower, range: searchStart..<lineLower.endIndex) {
                if matchCount == searchMatchIndex {
                    withAnimation {
                        proxy.scrollTo(index, anchor: .center)
                    }
                    return
                }
                matchCount += 1
                searchStart = range.upperBound
            }
        }
    }

    private func isLineCurrentMatch(lineIndex: Int) -> Bool {
        guard !searchText.isEmpty else { return false }
        let lines = logOutput.components(separatedBy: "\n")
        let searchLower = searchText.lowercased()
        var matchCount = 0
        for (index, line) in lines.enumerated() {
            let lineLower = line.lowercased()
            var searchStart = lineLower.startIndex
            while let range = lineLower.range(of: searchLower, range: searchStart..<lineLower.endIndex) {
                if index == lineIndex && matchCount == searchMatchIndex {
                    return true
                }
                matchCount += 1
                searchStart = range.upperBound
                if matchCount > searchMatchIndex { return false }
            }
            if index > lineIndex { return false }
        }
        return false
    }
}

struct LogLineView: View {
    let line: String
    let lineNumber: Int
    let searchText: String
    let isCurrentMatch: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(lineNumber)")
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)

            if searchText.isEmpty {
                Text(line)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                highlightedText
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 1)
        .background(isCurrentMatch ? Color.yellow.opacity(0.2) : Color.clear)
    }

    private var highlightedText: Text {
        let searchLower = searchText.lowercased()
        let lineLower = line.lowercased()
        var attributed = AttributedString(line)

        var searchStart = lineLower.startIndex
        while let range = lineLower.range(of: searchLower, range: searchStart..<lineLower.endIndex) {
            let attrRange = Range(uncheckedBounds: (
                AttributedString.Index(range.lowerBound, within: attributed)!,
                AttributedString.Index(range.upperBound, within: attributed)!
            ))
            attributed[attrRange].backgroundColor = .yellow
            attributed[attrRange].foregroundColor = .black
            searchStart = range.upperBound
        }

        return Text(attributed)
    }
}

extension String {
    func countOccurrences(of search: String) -> Int {
        guard !search.isEmpty else { return 0 }
        let searchLower = search.lowercased()
        let selfLower = self.lowercased()
        var count = 0
        var searchStart = selfLower.startIndex
        while let range = selfLower.range(of: searchLower, range: searchStart..<selfLower.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
