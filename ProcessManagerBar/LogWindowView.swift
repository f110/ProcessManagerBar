import SwiftUI
import AppKit

struct LogWindowView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @ObservedObject var state: LogWindowState
    @ObservedObject var appLogger: AppLogger = AppLogger.shared
    @State private var searchText: String = ""
    @State private var isSearchVisible = false
    @State private var searchMatchIndex: Int = 0
    @State private var isPaletteVisible = false
    @State private var paletteText = ""
    @State private var paletteSelectedIndex = 0
    @State private var jsonParseEnabledByTab: [String: Bool] = [:]

    private let appTabId = "__app__"

    private var paletteTabs: [PaletteTab] {
        var tabs: [PaletteTab] = [
            PaletteTab(id: appTabId, title: "App", isAppTab: true, state: nil)
        ]
        for proc in supervisor.processes {
            tabs.append(PaletteTab(id: proc.id, title: proc.config.name, isAppTab: false, state: proc.state))
        }
        return tabs
    }

    private var filteredPaletteTabs: [PaletteTab] {
        if paletteText.isEmpty { return paletteTabs }
        let lower = paletteText.lowercased()
        return paletteTabs.filter { $0.title.lowercased().contains(lower) }
    }

    private func closePalette() {
        isPaletteVisible = false
        paletteText = ""
        paletteSelectedIndex = 0
    }

    private var jsonParseBinding: Binding<Bool> {
        Binding(
            get: {
                let tab = state.selectedTab
                guard tab != appTabId else { return false }
                return jsonParseEnabledByTab[tab] ?? false
            },
            set: { newValue in
                let tab = state.selectedTab
                guard tab != appTabId else { return }
                jsonParseEnabledByTab[tab] = newValue
            }
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            mainContent

            if isPaletteVisible {
                TabPaletteView(
                    searchText: $paletteText,
                    selectedIndex: $paletteSelectedIndex,
                    tabs: filteredPaletteTabs,
                    onSelect: { tabId in
                        state.selectedTab = tabId
                        closePalette()
                    },
                    onClose: closePalette
                )
                .padding(.top, 60)
            }
        }
        .onChange(of: state.selectedTab) {
            searchText = ""
            searchMatchIndex = 0
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !isPaletteVisible else { return event }
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
                    isSearchVisible = true
                    return nil
                }
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "p" {
                    paletteText = ""
                    paletteSelectedIndex = 0
                    isPaletteVisible = true
                    return nil
                }
                return event
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        // App log tab
                        Button(action: {
                            state.selectedTab = appTabId
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 9))
                                Text("App")
                                    .font(.system(size: 12, weight: state.selectedTab == appTabId ? .semibold : .regular))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(state.selectedTab == appTabId ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                            .foregroundColor(state.selectedTab == appTabId ? .accentColor : .primary)
                        }
                        .buttonStyle(.plain)

                        ForEach(supervisor.processes) { proc in
                            TabButton(
                                title: proc.config.name,
                                state: proc.state,
                                isSelected: state.selectedTab == proc.id
                            ) {
                                state.selectedTab = proc.id
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                if state.selectedTab != appTabId {
                    Toggle(isOn: jsonParseBinding) {
                        Text("JSON")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.trailing, 12)
                }
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
            if state.selectedTab == appTabId {
                LogContentView(
                    logOutput: appLogger.logOutput,
                    jsonLogFormatter: nil,
                    searchText: searchText,
                    searchMatchIndex: searchMatchIndex
                )
            } else if let proc = selectedProcess {
                LogContentView(
                    logOutput: proc.logOutput,
                    jsonLogFormatter: (jsonParseEnabledByTab[proc.id] ?? false) ? proc.jsonLogFormatter : nil,
                    searchText: searchText,
                    searchMatchIndex: searchMatchIndex
                )
            } else {
                Text("タブを選択してください")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
    }

    private var selectedProcess: ManagedProcess? {
        supervisor.processes.first { $0.id == state.selectedTab }
    }

    private var currentMatchCount: Int {
        if state.selectedTab == appTabId {
            guard !searchText.isEmpty else { return 0 }
            return appLogger.logOutput.countOccurrences(of: searchText)
        }
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

class ClickableLogTextView: NSTextView {
    var onStackTraceClick: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func isOverStackTrace(at event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        guard let storage = textStorage, charIndex < storage.length else { return false }
        return storage.attribute(.stackTraceLineIndex, at: charIndex, effectiveRange: nil) != nil
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverStackTrace(at: event) {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverStackTrace(at: event) {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        guard let storage = textStorage, charIndex < storage.length else {
            super.mouseDown(with: event)
            return
        }
        if let lineIndex = storage.attribute(.stackTraceLineIndex, at: charIndex, effectiveRange: nil) as? Int {
            onStackTraceClick?(lineIndex)
            return
        }
        super.mouseDown(with: event)
    }
}

extension NSAttributedString.Key {
    static let stackTraceLineIndex = NSAttributedString.Key("stackTraceLineIndex")
}

struct LogContentView: NSViewRepresentable {
    let logOutput: String
    let jsonLogFormatter: JsonLogFormatter?
    let searchText: String
    let searchMatchIndex: Int

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ClickableLogTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        let coordinator = context.coordinator
        textView.onStackTraceClick = { [weak coordinator] lineIndex in
            guard let coordinator = coordinator else { return }
            if coordinator.expandedStackTraces.contains(lineIndex) {
                coordinator.expandedStackTraces.remove(lineIndex)
            } else {
                coordinator.expandedStackTraces.insert(lineIndex)
            }
            coordinator.needsRebuild = true
            // Trigger rebuild
            DispatchQueue.main.async {
                coordinator.rebuildContent()
            }
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let textView = coordinator.textView!

        let logChanged = coordinator.lastLogOutput != logOutput
        let formatterChanged = coordinator.lastFormatterEnabled != (jsonLogFormatter != nil)
        let searchChanged = coordinator.lastSearchText != searchText || coordinator.lastSearchMatchIndex != searchMatchIndex

        coordinator.currentLogOutput = logOutput
        coordinator.currentFormatter = jsonLogFormatter
        coordinator.currentSearchText = searchText
        coordinator.currentSearchMatchIndex = searchMatchIndex

        if logChanged || formatterChanged || coordinator.needsRebuild {
            coordinator.lastLogOutput = logOutput
            coordinator.lastFormatterEnabled = jsonLogFormatter != nil
            coordinator.needsRebuild = false

            let wasAtBottom = coordinator.isScrolledToBottom()

            let attrStr = buildAttributedString(expandedStackTraces: coordinator.expandedStackTraces)
            textView.textStorage?.setAttributedString(attrStr)

            if wasAtBottom && searchText.isEmpty {
                DispatchQueue.main.async {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }

        if searchChanged || logChanged || formatterChanged {
            coordinator.lastSearchText = searchText
            coordinator.lastSearchMatchIndex = searchMatchIndex
            highlightSearch(in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: ClickableLogTextView?
        var scrollView: NSScrollView?
        var lastLogOutput: String = ""
        var lastFormatterEnabled: Bool = false
        var lastSearchText: String = ""
        var lastSearchMatchIndex: Int = 0
        var expandedStackTraces: Set<Int> = []
        var needsRebuild = false

        var currentLogOutput: String = ""
        var currentFormatter: JsonLogFormatter?
        var currentSearchText: String = ""
        var currentSearchMatchIndex: Int = 0

        func isScrolledToBottom() -> Bool {
            guard let scrollView = scrollView, let documentView = scrollView.documentView else { return true }
            let visibleRect = scrollView.contentView.bounds
            let documentHeight = documentView.frame.height
            return visibleRect.maxY >= documentHeight - 20
        }

        func rebuildContent() {
            guard let textView = textView else { return }
            let wasAtBottom = isScrolledToBottom()
            let attrStr = buildAttributedStringFromCoordinator()
            textView.textStorage?.setAttributedString(attrStr)
            if wasAtBottom && currentSearchText.isEmpty {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private func buildAttributedStringFromCoordinator() -> NSAttributedString {
            let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let lines = currentLogOutput.components(separatedBy: "\n")
            let result = NSMutableAttributedString()

            var i = 0
            while i < lines.count {
                let line = lines[i]
                let formatted: JsonLogFormatter.FormatResult?
                let consumed: Int
                if let formatter = currentFormatter,
                   let panic = formatter.parsePanic(lines: lines, startIndex: i) {
                    formatted = panic.result
                    consumed = panic.consumedLines
                } else {
                    formatted = currentFormatter?.format(line)
                    consumed = 1
                }
                let index = i
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

                // Stack trace (collapsible)
                if let frames = formatted?.stackTrace, !frames.isEmpty {
                    if expandedStackTraces.contains(index) {
                        let header = " ▼ stack trace (\(frames.count) frames)"
                        let headerAttr = NSMutableAttributedString(string: header, attributes: [
                            .font: monoFont,
                            .foregroundColor: NSColor.systemOrange,
                            .stackTraceLineIndex: index,
                        ])
                        result.append(headerAttr)
                        for frame in frames {
                            let frameLine: String
                            if frame.filePath.isEmpty {
                                frameLine = "\n    \(frame.functionName)"
                            } else {
                                frameLine = "\n    \(frame.functionName)\n        \(frame.filePath):\(frame.line)"
                            }
                            let frameAttr = NSAttributedString(string: frameLine, attributes: [
                                .font: monoFont,
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ])
                            result.append(frameAttr)
                        }
                    } else {
                        let header = " ▶ stack trace (\(frames.count) frames)"
                        let headerAttr = NSMutableAttributedString(string: header, attributes: [
                            .font: monoFont,
                            .foregroundColor: NSColor.systemOrange,
                            .stackTraceLineIndex: index,
                        ])
                        result.append(headerAttr)
                    }
                }

                i += consumed
                if i < lines.count {
                    result.append(NSAttributedString(string: "\n"))
                }
            }
            return result
        }

        private func levelNSColor(_ level: JsonLogFormatter.LogLevel) -> NSColor {
            switch level {
            case .info: return NSColor(red: 0.2, green: 0.55, blue: 0.8, alpha: 1.0)
            case .warn: return NSColor(red: 0.7, green: 0.5, blue: 0.0, alpha: 1.0)
            case .error: return NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1.0)
            case .fatal, .panic: return NSColor(red: 0.6, green: 0.0, blue: 0.0, alpha: 1.0)
            default: return .labelColor
            }
        }
    }

    private func buildAttributedString(expandedStackTraces: Set<Int>) -> NSAttributedString {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lines = logOutput.components(separatedBy: "\n")
        let result = NSMutableAttributedString()

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let formatted: JsonLogFormatter.FormatResult?
            let consumed: Int
            if let formatter = jsonLogFormatter,
               let panic = formatter.parsePanic(lines: lines, startIndex: i) {
                formatted = panic.result
                consumed = panic.consumedLines
            } else {
                formatted = jsonLogFormatter?.format(line)
                consumed = 1
            }
            let index = i
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

            // Stack trace (collapsible)
            if let frames = formatted?.stackTrace, !frames.isEmpty {
                if expandedStackTraces.contains(index) {
                    let header = " ▼ stack trace (\(frames.count) frames)"
                    let headerAttr = NSMutableAttributedString(string: header, attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor.systemOrange,
                        .stackTraceLineIndex: index,
                    ])
                    result.append(headerAttr)
                    for frame in frames {
                        let frameLine: String
                        if frame.filePath.isEmpty {
                            frameLine = "\n    \(frame.functionName)"
                        } else {
                            frameLine = "\n    \(frame.functionName)\n        \(frame.filePath):\(frame.line)"
                        }
                        let frameAttr = NSAttributedString(string: frameLine, attributes: [
                            .font: monoFont,
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ])
                        result.append(frameAttr)
                    }
                } else {
                    let header = " ▶ stack trace (\(frames.count) frames)"
                    let headerAttr = NSMutableAttributedString(string: header, attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor.systemOrange,
                        .stackTraceLineIndex: index,
                    ])
                    result.append(headerAttr)
                }
            }

            i += consumed
            if i < lines.count {
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
    private let timestampKeys: [String] = ["time", "timestamp", "ts", "t"]
    private let levelKeys: Set<String> = ["level", "lvl", "severity"]
    private let messageKeys: Set<String> = ["msg", "message"]
    private let callerKeys: Set<String> = ["caller", "source"]
    private let errorKeys: Set<String> = ["error", "err"]

    private var cachedTimestampParser: TimestampParser?
    // Tracks the wall-clock time we first observed each panic block, keyed by
    // its raw text. The cache lets re-renders display a stable timestamp.
    private var panicTimestamps: [String: Date] = [:]

    enum LogLevel: Equatable {
        case trace, debug, info, warn, error, fatal, panic, unknown
    }

    struct StackFrame {
        let functionName: String
        let filePath: String
        let line: String
    }

    struct FormatResult {
        let text: String
        let level: LogLevel
        let levelNSRange: NSRange?
        let messageNSRange: NSRange?
        let keyNSRanges: [NSRange]
        let stackTrace: [StackFrame]?
    }

    func format(_ line: String) -> FormatResult {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FormatResult(text: line, level: .unknown, levelNSRange: nil, messageNSRange: nil, keyNSRanges: [], stackTrace: nil)
        }

        var remaining = obj

        // Extract special fields
        let timestamp = Self.extractFirstOrdered(from: &remaining, keys: timestampKeys)
        let levelVal = Self.extractFirst(from: &remaining, keys: levelKeys)
        let message = Self.extractFirst(from: &remaining, keys: messageKeys)
        let caller = Self.extractFirst(from: &remaining, keys: callerKeys)
        let errorVal = Self.extractFirst(from: &remaining, keys: errorKeys)
        let stackVal = remaining.removeValue(forKey: "error.stack")
            ?? remaining.removeValue(forKey: "stacktrace")

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

        // Remaining fields in sorted order — nested objects are flattened to dot-notation
        for key in remaining.keys.sorted() {
            for (flatKey, valStr) in Self.flattenField(key: key, value: remaining[key]!) {
                let currentText = parts.joined(separator: " ")
                let startOffset = currentText.isEmpty ? 0 : (currentText as NSString).length + 1
                keyNSRanges.append(NSRange(location: startOffset, length: (flatKey as NSString).length))
                parts.append("\(flatKey)=\(valStr)")
            }
        }

        // Parse stack trace
        let parsedStack: [StackFrame]?
        if let sv = stackVal {
            parsedStack = Self.parseStackTrace(Self.stringValue(sv))
        } else {
            parsedStack = nil
        }

        // Caller — at the end with arrow (skip if stack trace is available)
        if parsedStack == nil, let c = caller {
            parts.append("→ \(Self.stringValue(c))")
        }

        return FormatResult(text: parts.joined(separator: " "), level: logLevel, levelNSRange: levelNSRange, messageNSRange: messageNSRange, keyNSRanges: keyNSRanges, stackTrace: parsedStack)
    }

    // Detects a Go runtime panic that spans multiple lines starting at `startIndex`.
    // Returns the synthesized FormatResult and how many input lines were consumed,
    // or nil if the lines do not look like a panic (no goroutine header).
    func parsePanic(lines: [String], startIndex: Int) -> (result: FormatResult, consumedLines: Int)? {
        guard startIndex < lines.count else { return nil }
        let firstLine = lines[startIndex]
        let trimmedFirst = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmedFirst.hasPrefix("{") { return nil }
        guard let panicRange = firstLine.range(of: "panic:") else { return nil }

        let panicMessage = String(firstLine[panicRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        var consumed = 1
        var i = startIndex + 1

        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
            consumed += 1
        }

        guard i < lines.count else { return nil }
        let goroutineLine = lines[i].trimmingCharacters(in: .whitespaces)
        guard goroutineLine.hasPrefix("goroutine "), goroutineLine.hasSuffix(":") else {
            return nil
        }
        let goroutineInfo = String(goroutineLine.dropFirst("goroutine ".count).dropLast())
        i += 1
        consumed += 1

        // Each frame is a function line followed by an indented file line.
        // Stack-trace lines always have a whitespace-indented file line; if the
        // line we'd take as a file line doesn't start with whitespace, the
        // current line isn't part of the panic — bail out and let normal log
        // parsing handle it.
        var frames: [StackFrame] = []
        while i + 1 < lines.count {
            let line = lines[i]
            let nextLine = lines[i + 1]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if line.hasPrefix("{") { break }
            if !(nextLine.first == "\t" || nextLine.hasPrefix(" ")) { break }

            let funcLine = trimmed
            let fileLine = nextLine.trimmingCharacters(in: .whitespaces)
            let fileParts = fileLine.components(separatedBy: ":")
            if fileParts.count >= 2 {
                let path = fileParts[0]
                let lineNum = fileParts[1].components(separatedBy: " ").first ?? fileParts[1]
                frames.append(StackFrame(functionName: funcLine, filePath: path, line: lineNum))
            } else {
                frames.append(StackFrame(functionName: funcLine, filePath: fileLine, line: ""))
            }
            i += 2
            consumed += 2
        }

        // Cache the wall-clock time of first detection so the displayed
        // timestamp doesn't drift on every re-render.
        let cacheKey = lines[startIndex..<(startIndex + consumed)].joined(separator: "\n")
        let timestamp: Date
        if let cached = panicTimestamps[cacheKey] {
            timestamp = cached
        } else {
            timestamp = Date()
            panicTimestamps[cacheKey] = timestamp
        }
        let timestampStr = Self.formatDate(timestamp, includeFraction: true)

        var parts: [String] = [timestampStr]

        let levelPart = "│PNC│"
        let beforeLevel = parts.joined(separator: " ")
        let levelOffset = (beforeLevel as NSString).length + 1
        let levelNSRange = NSRange(location: levelOffset, length: (levelPart as NSString).length)
        parts.append(levelPart)

        var messageNSRange: NSRange?
        if !panicMessage.isEmpty {
            let beforeMsg = parts.joined(separator: " ")
            let msgOffset = (beforeMsg as NSString).length + 1
            messageNSRange = NSRange(location: msgOffset, length: (panicMessage as NSString).length)
            parts.append(panicMessage)
        }

        var keyNSRanges: [NSRange] = []
        let beforeGoroutine = parts.joined(separator: " ")
        let goroutineKeyOffset = (beforeGoroutine as NSString).length + 1
        keyNSRanges.append(NSRange(location: goroutineKeyOffset, length: ("goroutine" as NSString).length))
        parts.append("goroutine=\(goroutineInfo)")

        return (
            FormatResult(
                text: parts.joined(separator: " "),
                level: .panic,
                levelNSRange: levelNSRange,
                messageNSRange: messageNSRange,
                keyNSRanges: keyNSRanges,
                stackTrace: frames.isEmpty ? nil : frames
            ),
            consumed
        )
    }

    static func parseStackTrace(_ raw: String) -> [StackFrame]? {
        let lines = raw.components(separatedBy: "\n")
        var frames: [StackFrame] = []
        var i = 0
        while i < lines.count {
            let funcLine = lines[i].trimmingCharacters(in: .whitespaces)
            guard !funcLine.isEmpty else { i += 1; continue }
            i += 1
            guard i < lines.count else {
                // Single line without file info — still a frame
                frames.append(StackFrame(functionName: funcLine, filePath: "", line: ""))
                break
            }
            let fileLine = lines[i].trimmingCharacters(in: .whitespaces)
            if fileLine.contains(":") && !fileLine.hasPrefix("/") == false || fileLine.contains(":") {
                // Parse "filepath:lineNumber" or "filepath:lineNumber +0xoffset"
                let parts = fileLine.components(separatedBy: ":")
                if parts.count >= 2 {
                    let path = parts[0]
                    let lineNum = parts[1].components(separatedBy: " ").first ?? parts[1]
                    frames.append(StackFrame(functionName: funcLine, filePath: path, line: lineNum))
                } else {
                    frames.append(StackFrame(functionName: funcLine, filePath: fileLine, line: ""))
                }
                i += 1
            } else {
                // No file line follows — treat current as function only
                frames.append(StackFrame(functionName: funcLine, filePath: "", line: ""))
            }
        }
        return frames.isEmpty ? nil : frames
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

    // Returns the first matching value by key priority, and drops all other
    // matching keys from `obj` so duplicates don't leak into the output.
    private static func extractFirstOrdered(from obj: inout [String: Any], keys: [String]) -> Any? {
        var result: Any?
        for key in keys {
            if let value = obj.removeValue(forKey: key), result == nil {
                result = value
            }
        }
        return result
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

    // Flattens a nested dictionary into dot-notation (key=value) pairs.
    // Non-dictionary values and empty dictionaries are returned as a single pair.
    static func flattenField(key: String, value: Any) -> [(key: String, valueStr: String)] {
        if let dict = value as? [String: Any], !dict.isEmpty {
            var results: [(String, String)] = []
            for childKey in dict.keys.sorted() {
                let fullKey = "\(key).\(childKey)"
                results.append(contentsOf: flattenField(key: fullKey, value: dict[childKey]!))
            }
            return results
        }
        return [(key, stringValue(value))]
    }

    static func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
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

struct PaletteTab: Identifiable {
    let id: String
    let title: String
    let isAppTab: Bool
    let state: ProcessState?
}

final class PaletteLiveTabs {
    var value: [PaletteTab] = []
}

struct TabPaletteView: View {
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    let tabs: [PaletteTab]
    let onSelect: (String) -> Void
    let onClose: () -> Void
    @FocusState private var isTextFieldFocused: Bool
    @State private var eventMonitor: Any?
    @State private var liveTabs = PaletteLiveTabs()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("タブを検索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isTextFieldFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if tabs.isEmpty {
                Divider()
                Text("タブが見つかりません")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(20)
            } else {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                paletteRow(index: index, tab: tab)
                                    .id(tab.id)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: selectedIndex) {
                        guard selectedIndex >= 0 && selectedIndex < tabs.count else { return }
                        proxy.scrollTo(tabs[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 4)
        .onAppear {
            liveTabs.value = tabs
            isTextFieldFocused = true
            installEventMonitor()
        }
        .onDisappear {
            removeEventMonitor()
        }
        .onChange(of: searchText) {
            selectedIndex = 0
        }
        .onChange(of: tabs.map(\.id)) {
            liveTabs.value = tabs
        }
    }

    @ViewBuilder
    private func paletteRow(index: Int, tab: PaletteTab) -> some View {
        Button(action: { onSelect(tab.id) }) {
            HStack(spacing: 8) {
                if tab.isAppTab {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .frame(width: 12)
                } else if let state = tab.state {
                    Circle()
                        .fill(stateColor(state))
                        .frame(width: 7, height: 7)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Text(tab.title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func installEventMonitor() {
        let live = liveTabs
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Escape
                onClose()
                return nil
            case 126: // Up arrow
                if !live.value.isEmpty {
                    selectedIndex = max(0, selectedIndex - 1)
                }
                return nil
            case 125: // Down arrow
                if !live.value.isEmpty {
                    selectedIndex = min(live.value.count - 1, selectedIndex + 1)
                }
                return nil
            case 36, 76: // Return / Enter
                commitSelection()
                return nil
            default:
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "p" {
                    onClose()
                    return nil
                }
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitor = nil
    }

    private func commitSelection() {
        let current = liveTabs.value
        guard !current.isEmpty else {
            onClose()
            return
        }
        let idx = max(0, min(selectedIndex, current.count - 1))
        onSelect(current[idx].id)
    }

    private func stateColor(_ state: ProcessState) -> Color {
        switch state {
        case .stopped: return .red
        case .running: return .green
        case .needsRestart: return .yellow
        case .error: return .orange
        }
    }
}
