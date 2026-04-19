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
                                state: proc.state,
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
                        jsonLogFormatter: (proc.config.jsonLog ?? false) ? proc.jsonLogFormatter : nil,
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
    let state: ProcessState
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
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

    private var stateColor: Color {
        switch state {
        case .stopped: return .red
        case .running: return .green
        case .needsRestart: return .yellow
        case .error: return .orange
        }
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

struct LogContentView: NSViewRepresentable {
    let logOutput: String
    let jsonLogFormatter: JsonLogFormatter?
    let searchText: String
    let searchMatchIndex: Int

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let textView = coordinator.textView!

        let logChanged = coordinator.lastLogOutput != logOutput
        let searchChanged = coordinator.lastSearchText != searchText || coordinator.lastSearchMatchIndex != searchMatchIndex

        if logChanged {
            coordinator.lastLogOutput = logOutput

            let wasAtBottom = coordinator.isScrolledToBottom()

            let attrStr = buildAttributedString()
            textView.textStorage?.setAttributedString(attrStr)

            if wasAtBottom && searchText.isEmpty {
                DispatchQueue.main.async {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }

        if searchChanged || logChanged {
            coordinator.lastSearchText = searchText
            coordinator.lastSearchMatchIndex = searchMatchIndex
            highlightSearch(in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var lastLogOutput: String = ""
        var lastSearchText: String = ""
        var lastSearchMatchIndex: Int = 0

        func isScrolledToBottom() -> Bool {
            guard let scrollView = scrollView, let documentView = scrollView.documentView else { return true }
            let visibleRect = scrollView.contentView.bounds
            let documentHeight = documentView.frame.height
            return visibleRect.maxY >= documentHeight - 20
        }
    }

    private func buildAttributedString() -> NSAttributedString {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lines = logOutput.components(separatedBy: "\n")
        let result = NSMutableAttributedString()

        for (index, line) in lines.enumerated() {
            let formatted = jsonLogFormatter?.format(line)
            let displayText = formatted?.text ?? line
            let level = formatted?.level ?? .unknown

            let baseOffset = result.length
            let textAttr = NSAttributedString(string: displayText, attributes: [
                .font: monoFont,
                .foregroundColor: NSColor.labelColor,
            ])
            result.append(textAttr)

            if let levelRange = formatted?.levelNSRange, level != .unknown {
                let adjustedRange = NSRange(location: baseOffset + levelRange.location, length: levelRange.length)
                result.addAttribute(.foregroundColor, value: levelNSColor(level), range: adjustedRange)
            }

            if let msgRange = formatted?.messageNSRange {
                let adjustedRange = NSRange(location: baseOffset + msgRange.location, length: msgRange.length)
                let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
                result.addAttribute(.font, value: boldFont, range: adjustedRange)
            }

            if let keyRanges = formatted?.keyNSRanges {
                for keyRange in keyRanges {
                    let adjustedRange = NSRange(location: baseOffset + keyRange.location, length: keyRange.length)
                    result.addAttribute(.foregroundColor, value: NSColor(red: 0.55, green: 0.47, blue: 0.75, alpha: 1.0), range: adjustedRange)
                }
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private func levelNSColor(_ level: JsonLogFormatter.LogLevel) -> NSColor {
        switch level {
        case .info:
            return NSColor(red: 0.2, green: 0.55, blue: 0.8, alpha: 1.0)
        case .warn:
            return NSColor(red: 0.7, green: 0.5, blue: 0.0, alpha: 1.0)
        case .error:
            return NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1.0)
        case .fatal, .panic:
            return NSColor(red: 0.6, green: 0.0, blue: 0.0, alpha: 1.0)
        default:
            return .labelColor
        }
    }

    private func highlightSearch(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        // Remove previous search highlights
        storage.removeAttribute(.backgroundColor, range: fullRange)

        guard !searchText.isEmpty else { return }

        let text = storage.string as NSString
        let searchLower = searchText.lowercased()
        let textLower = text.lowercased as NSString

        var matchCount = 0
        var searchRange = NSRange(location: 0, length: textLower.length)

        while searchRange.location < textLower.length {
            let range = textLower.range(of: searchLower, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }

            let bgColor: NSColor = (matchCount == searchMatchIndex) ? .systemYellow : .systemYellow.withAlphaComponent(0.3)
            storage.addAttribute(.backgroundColor, value: bgColor, range: range)

            if matchCount == searchMatchIndex {
                // Scroll to current match
                textView.scrollRangeToVisible(range)
            }

            matchCount += 1
            searchRange.location = range.location + range.length
            searchRange.length = textLower.length - searchRange.location
        }
    }
}

class JsonLogFormatter {
    private let timestampKeys: Set<String> = ["time", "timestamp", "ts", "t"]
    private let levelKeys: Set<String> = ["level", "lvl", "severity"]
    private let messageKeys: Set<String> = ["msg", "message"]
    private let callerKeys: Set<String> = ["caller", "source"]
    private let errorKeys: Set<String> = ["error", "err"]

    private var cachedTimestampParser: TimestampParser?

    enum LogLevel: Equatable {
        case trace, debug, info, warn, error, fatal, panic, unknown
    }

    struct FormatResult {
        let text: String
        let level: LogLevel
        let levelNSRange: NSRange?
        let messageNSRange: NSRange?
        let keyNSRanges: [NSRange]
    }

    func format(_ line: String) -> FormatResult {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FormatResult(text: line, level: .unknown, levelNSRange: nil, messageNSRange: nil, keyNSRanges: [])
        }

        var remaining = obj

        // Extract special fields
        let timestamp = Self.extractFirst(from: &remaining, keys: timestampKeys)
        let levelVal = Self.extractFirst(from: &remaining, keys: levelKeys)
        let message = Self.extractFirst(from: &remaining, keys: messageKeys)
        let caller = Self.extractFirst(from: &remaining, keys: callerKeys)
        let errorVal = Self.extractFirst(from: &remaining, keys: errorKeys)

        let levelStr = levelVal.map { Self.stringValue($0) } ?? ""
        let logLevel = Self.parseLogLevel(levelStr)

        var parts: [String] = []

        // Timestamp — formatted, no field name
        if let ts = timestamp {
            parts.append(formatTimestamp(Self.stringValue(ts)))
        }

        // Level — short label (track position for coloring)
        var levelNSRange: NSRange?
        if !levelStr.isEmpty {
            let levelPart = "│\(Self.formatLevel(levelStr))│"
            let currentText = parts.joined(separator: " ")
            let startOffset = currentText.isEmpty ? 0 : (currentText as NSString).length + 1
            levelNSRange = NSRange(location: startOffset, length: (levelPart as NSString).length)
            parts.append(levelPart)
        }

        // Message — no field name (track position for bold)
        var messageNSRange: NSRange?
        if let msg = message {
            let msgText = Self.stringValue(msg)
            let currentText = parts.joined(separator: " ")
            let startOffset = currentText.isEmpty ? 0 : (currentText as NSString).length + 1
            messageNSRange = NSRange(location: startOffset, length: (msgText as NSString).length)
            parts.append(msgText)
        }

        // Error field and remaining fields — track key ranges
        var keyNSRanges: [NSRange] = []

        if let err = errorVal {
            let currentText = parts.joined(separator: " ")
            let startOffset = currentText.isEmpty ? 0 : (currentText as NSString).length + 1
            keyNSRanges.append(NSRange(location: startOffset, length: ("error" as NSString).length))
            parts.append("error=\(Self.stringValue(err))")
        }

        // Remaining fields in sorted order
        for key in remaining.keys.sorted() {
            let currentText = parts.joined(separator: " ")
            let startOffset = currentText.isEmpty ? 0 : (currentText as NSString).length + 1
            keyNSRanges.append(NSRange(location: startOffset, length: (key as NSString).length))
            parts.append("\(key)=\(Self.stringValue(remaining[key]!))")
        }

        // Caller — at the end with arrow
        if let c = caller {
            parts.append("→ \(Self.stringValue(c))")
        }

        return FormatResult(text: parts.joined(separator: " "), level: logLevel, levelNSRange: levelNSRange, messageNSRange: messageNSRange, keyNSRanges: keyNSRanges)
    }

    private static func parseLogLevel(_ level: String) -> LogLevel {
        switch level.lowercased() {
        case "trace", "trc": return .trace
        case "debug", "dbg": return .debug
        case "info", "inf": return .info
        case "warn", "warning", "wrn": return .warn
        case "error", "err": return .error
        case "fatal", "ftl": return .fatal
        case "panic", "pnc": return .panic
        default: return .unknown
        }
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

    // MARK: - Timestamp parsing with caching

    enum TimestampParser {
        case iso8601Frac
        case iso8601
        case dateFormat(String)
        case unixTimestamp
    }

    func formatTimestamp(_ raw: String) -> String {
        // Use cached parser if available
        if let parser = cachedTimestampParser {
            if let result = applyParser(parser, to: raw) {
                return result
            }
            // Cache miss (format changed?), fall through to detection
        }

        // Detect format and cache it
        if let (parser, result) = detectTimestampFormat(raw) {
            cachedTimestampParser = parser
            return result
        }
        return raw
    }

    private func applyParser(_ parser: TimestampParser, to raw: String) -> String? {
        switch parser {
        case .iso8601Frac:
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fmt.date(from: raw) else { return nil }
            return Self.formatDatePreservingFraction(raw, date: date)
        case .iso8601:
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            guard let date = fmt.date(from: raw) else { return nil }
            return Self.formatDate(date, includeFraction: false)
        case .dateFormat(let pattern):
            let df = Self.makeDateFormatter(pattern: pattern)
            guard let date = df.date(from: raw) else { return nil }
            return Self.formatDate(date, includeFraction: false)
        case .unixTimestamp:
            guard let seconds = Double(raw) else { return nil }
            let date = Date(timeIntervalSince1970: seconds)
            let fraction = seconds.truncatingRemainder(dividingBy: 1)
            return Self.formatDate(date, includeFraction: fraction != 0)
        }
    }

    private func detectTimestampFormat(_ raw: String) -> (TimestampParser, String)? {
        // RFC3339 with fractional seconds (including nanosecond precision)
        let iso8601Frac = ISO8601DateFormatter()
        iso8601Frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601Frac.date(from: raw) {
            return (.iso8601Frac, Self.formatDatePreservingFraction(raw, date: date))
        }
        // RFC3339 without fractional seconds
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: raw) {
            return (.iso8601, Self.formatDate(date, includeFraction: false))
        }
        // RFC1123 / RFC822 / RFC850
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
            let df = Self.makeDateFormatter(pattern: fmt)
            if let date = df.date(from: raw) {
                return (.dateFormat(fmt), Self.formatDate(date, includeFraction: false))
            }
        }
        // Unix timestamp
        if let seconds = Double(raw) {
            let date = Date(timeIntervalSince1970: seconds)
            let fraction = seconds.truncatingRemainder(dividingBy: 1)
            return (.unixTimestamp, Self.formatDate(date, includeFraction: fraction != 0))
        }
        return nil
    }

    private static func makeDateFormatter(pattern: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = pattern
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        df.twoDigitStartDate = cal.date(from: DateComponents(year: 2000, month: 1, day: 1))
        return df
    }

    private static func formatDatePreservingFraction(_ raw: String, date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        let base = df.string(from: date)

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

    static func stringValue(_ value: Any) -> String {
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
