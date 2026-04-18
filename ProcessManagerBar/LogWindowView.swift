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
                        jsonLog: proc.config.jsonLog ?? false,
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
    let jsonLog: Bool
    let searchText: String
    let searchMatchIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lines = logOutput.components(separatedBy: "\n")
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let displayLine = jsonLog ? JsonLogFormatter.format(line) : line
                        LogLineView(
                            line: displayLine,
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

enum JsonLogFormatter {
    private static let timestampKeys: Set<String> = ["time", "timestamp", "ts", "t"]
    private static let levelKeys: Set<String> = ["level", "lvl", "severity"]
    private static let messageKeys: Set<String> = ["msg", "message"]
    private static let callerKeys: Set<String> = ["caller", "source"]
    private static let errorKeys: Set<String> = ["error", "err"]
    private static let specialKeys: Set<String> = timestampKeys.union(levelKeys).union(messageKeys).union(callerKeys).union(errorKeys)

    static func format(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return line
        }

        var remaining = obj

        // Extract special fields
        let timestamp = extractFirst(from: &remaining, keys: timestampKeys)
        let level = extractFirst(from: &remaining, keys: levelKeys)
        let message = extractFirst(from: &remaining, keys: messageKeys)
        let caller = extractFirst(from: &remaining, keys: callerKeys)
        let errorVal = extractFirst(from: &remaining, keys: errorKeys)

        var parts: [String] = []

        // Timestamp — formatted, no field name
        if let ts = timestamp {
            parts.append(formatTimestamp(stringValue(ts)))
        }

        // Level — short label
        if let lv = level {
            parts.append("│\(formatLevel(stringValue(lv)))│")
        }

        // Message — no field name
        if let msg = message {
            parts.append(stringValue(msg))
        }

        // Error field
        if let err = errorVal {
            parts.append("error=\(stringValue(err))")
        }

        // Remaining fields in sorted order
        for key in remaining.keys.sorted() {
            parts.append("\(key)=\(stringValue(remaining[key]!))")
        }

        // Caller — at the end with arrow
        if let c = caller {
            parts.append("→ \(stringValue(c))")
        }

        return parts.joined(separator: " ")
    }

    private static func extractFirst(from obj: inout [String: Any], keys: Set<String>) -> Any? {
        for key in keys {
            if let value = obj.removeValue(forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func formatLevel(_ level: String) -> String {
        switch level.lowercased() {
        case "debug", "dbg": return "DBG"
        case "info", "inf": return "INF"
        case "warn", "warning", "wrn": return "WRN"
        case "error", "err": return "ERR"
        case "fatal", "ftl": return "FTL"
        case "panic", "pnc": return "PNC"
        case "trace", "trc": return "TRC"
        default: return level.uppercased().prefix(3).padding(toLength: 3, withPad: " ", startingAt: 0)
        }
    }

    static func formatTimestamp(_ raw: String) -> String {
        // RFC3339 with fractional seconds (including nanosecond precision)
        let iso8601Frac = ISO8601DateFormatter()
        iso8601Frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601Frac.date(from: raw) {
            // Preserve original fractional digits for nano precision
            return formatDatePreservingFraction(raw, date: date)
        }
        // RFC3339 without fractional seconds
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: raw) {
            return formatDate(date, includeFraction: false)
        }
        // RFC1123 / RFC822: "Mon, 02 Jan 2006 15:04:05 MST" or "Mon, 02 Jan 06 15:04:05 MST"
        // RFC850: "Monday, 02-Jan-06 15:04:05 MST"
        let dateFormats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC1123
            "EEE, dd MMM yyyy HH:mm:ss Z",      // RFC1123 with numeric TZ
            "EEE, dd MMM yy HH:mm:ss zzz",      // RFC822 with day-of-week
            "EEE, dd MMM yy HH:mm:ss Z",        // RFC822 with day-of-week, numeric TZ
            "dd MMM yy HH:mm Z",                 // RFC822 minimal (no day-of-week, no seconds)
            "dd MMM yy HH:mm:ss Z",              // RFC822 no day-of-week
            "dd MMM yy HH:mm zzz",               // RFC822 minimal with named TZ
            "dd MMM yy HH:mm:ss zzz",            // RFC822 no day-of-week, named TZ
            "EEEE, dd-MMM-yy HH:mm:ss zzz",     // RFC850
            "EEEE, dd-MMM-yy HH:mm:ss Z",       // RFC850 with numeric TZ
        ]
        for fmt in dateFormats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            // Ensure 2-digit years are interpreted as 2000s, not 1900s
            // 2-digit years: interpret as 2000-2099
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            df.twoDigitStartDate = cal.date(from: DateComponents(year: 2000, month: 1, day: 1))
            if let date = df.date(from: raw) {
                return formatDate(date, includeFraction: false)
            }
        }
        // Unix timestamp (seconds, possibly with fractional)
        if let seconds = Double(raw) {
            let date = Date(timeIntervalSince1970: seconds)
            let fraction = seconds.truncatingRemainder(dividingBy: 1)
            if fraction != 0 {
                return formatDate(date, includeFraction: true)
            }
            return formatDate(date, includeFraction: false)
        }
        return raw
    }

    private static func formatDatePreservingFraction(_ raw: String, date: Date) -> String {
        // Extract fractional part from original string for full precision
        let df = DateFormatter()
        df.dateFormat = "MMM dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        let base = df.string(from: date)

        // Find fractional part in the original string (after seconds "ss.fraction")
        if let dotRange = raw.range(of: "\\.\\d+", options: .regularExpression) {
            let frac = String(raw[dotRange])
            return base + frac
        }
        return base + ".000"
    }

    private static func formatDate(_ date: Date, includeFraction: Bool) -> String {
        let df = DateFormatter()
        df.dateFormat = includeFraction ? "MMM dd HH:mm:ss.SSS" : "MMM dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: date)
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case is NSNull:
            return "null"
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\(value)"
        }
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
