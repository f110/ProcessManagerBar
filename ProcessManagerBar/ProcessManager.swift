import Foundation
import Combine
import CoreServices

enum ProcessState: Equatable {
    case stopped
    case running
    case needsRestart
    case error(String)

    static func == (lhs: ProcessState, rhs: ProcessState) -> Bool {
        switch (lhs, rhs) {
        case (.stopped, .stopped), (.running, .running), (.needsRestart, .needsRestart):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

class ManagedProcess: ObservableObject, Identifiable {
    let config: ProcessConfig
    var id: String { config.name }

    @Published var state: ProcessState = .stopped
    @Published var logOutput: String = ""
    var maxLogLines: Int = Configuration.defaultMaxLogLines
    let jsonLogFormatter: JsonLogFormatter = JsonLogFormatter()

    init(config: ProcessConfig) {
        self.config = config
    }

    func start() {}
    func stop() {}
    func restart() {}
    func markNeedsRestart() {
        if state == .running {
            state = .needsRestart
        }
    }

    static let ignoredDirNames: Set<String> = [
        ".git", "node_modules", "vendor", ".build", "__pycache__", ".svn", ".hg",
        ".idea", ".jj",
    ]

    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    static func trimLog(_ log: inout String, maxLines: Int) {
        guard maxLines > 0 else { return }
        var newlineCount = 0
        for c in log where c == "\n" { newlineCount += 1 }
        guard newlineCount > maxLines else { return }
        let toSkip = newlineCount - maxLines
        var skipped = 0
        var idx = log.startIndex
        while idx < log.endIndex {
            if log[idx] == "\n" {
                skipped += 1
                if skipped == toSkip {
                    log = String(log[log.index(after: idx)...])
                    return
                }
            }
            idx = log.index(after: idx)
        }
    }
}

// MARK: - Local Managed Process

final class LocalManagedProcess: ManagedProcess {
    private var process: Process?
    private var logFileHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var eventStream: FSEventStreamRef?
    private var isRestarting = false

    override func start() {
        guard state != .running else { return }

        guard !config.command.isEmpty else {
            state = .error("コマンドが指定されていません")
            return
        }

        let expandedDir = Self.expandTilde(config.dir)
        let executable = Self.expandTilde(config.command[0])
        let resolvedPath: String

        if executable.contains("/") {
            let fullPath = executable.hasPrefix("/")
                ? executable
                : (expandedDir as NSString).appendingPathComponent(executable)
            guard FileManager.default.isExecutableFile(atPath: fullPath) else {
                state = .error("実行ファイルが見つかりません: \(executable)")
                return
            }
            resolvedPath = fullPath
        } else {
            guard let found = ShellEnvironment.shared.resolveExecutable(executable) else {
                state = .error("実行ファイルが見つかりません: \(executable)")
                return
            }
            resolvedPath = found
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedPath)
        proc.arguments = Array(config.command.dropFirst()).map {
            Self.expandTilde($0.replacingOccurrences(of: "$DIR", with: expandedDir))
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedDir)
        proc.environment = ShellEnvironment.shared.environment

        if let logPath = config.logFile {
            let expandedPath = Self.expandTilde(logPath)
            let logURL = URL(fileURLWithPath: expandedPath)
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: expandedPath, contents: nil)
            if let handle = FileHandle(forWritingAtPath: expandedPath) {
                handle.seekToEndOfFile()
                self.logFileHandle = handle
            }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let readHandler: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.logOutput.append(text)
                ManagedProcess.trimLog(&self.logOutput, maxLines: self.maxLogLines)
            }
            self?.logFileHandle?.write(data)
        }
        outPipe.fileHandleForReading.readabilityHandler = readHandler
        errPipe.fileHandleForReading.readabilityHandler = readHandler

        proc.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                if let handle = self.logFileHandle {
                    try? handle.close()
                    self.logFileHandle = nil
                }
                self.process = nil

                if self.isRestarting {
                    AppLogger.shared.log("[\(self.config.name)] process stopped for restart")
                    self.isRestarting = false
                    self.state = .stopped
                    self.start()
                    return
                }
                AppLogger.shared.log("[\(self.config.name)] process stopped (status=\(terminatedProcess.terminationStatus))")
                if self.state != .needsRestart {
                    self.state = .stopped
                }
                if terminatedProcess.terminationReason == .uncaughtSignal || terminatedProcess.terminationStatus != 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self, self.state == .stopped else { return }
                        self.start()
                    }
                }
            }
        }

        do {
            try proc.run()
            let childPid = proc.processIdentifier
            let myPgid = getpgrp()
            setpgid(childPid, myPgid)
            self.process = proc
            state = .running
            AppLogger.shared.log("[\(config.name)] process started (pid=\(childPid))")
            if config.watch ?? false {
                startFileWatching()
            }
        } catch {
            state = .error("起動失敗: \(error.localizedDescription)")
        }
    }

    override func stop() {
        AppLogger.shared.log("[\(config.name)] stopping process")
        stopFileWatching()
        guard let proc = process, proc.isRunning else {
            state = .stopped
            return
        }
        terminateProcess(proc)
    }

    override func restart() {
        AppLogger.shared.log("[\(config.name)] restarting process")
        stopFileWatching()
        guard let proc = process, proc.isRunning else {
            process = nil
            start()
            return
        }
        isRestarting = true
        terminateProcess(proc)
    }

    private func terminateProcess(_ proc: Process) {
        let pid = proc.processIdentifier
        kill(pid, SIGTERM)
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            if proc.isRunning {
                kill(pid, SIGKILL)
                proc.waitUntilExit()
            }
        }
    }

    // MARK: - File Watching (FSEvents)

    private func startFileWatching() {
        stopFileWatching()

        let pathToWatch = Self.expandTilde(config.dir) as CFString
        let pathsToWatch = [pathToWatch] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (
            streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds
        ) in
            guard let info = clientCallbackInfo else { return }
            let process = Unmanaged<LocalManagedProcess>.fromOpaque(info).takeUnretainedValue()

            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

            for i in 0..<numEvents {
                let path = paths[i]

                let components = path.split(separator: "/")
                if components.contains(where: { ManagedProcess.ignoredDirNames.contains(String($0)) }) {
                    continue
                }

                let flag = Int32(bitPattern: flags[i])
                _ = flag

                AppLogger.shared.log("[\(process.config.name)] file changed: \(path)")
                DispatchQueue.main.async {
                    process.markNeedsRestart()
                }
                return
            }
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(
                kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
            )
        )

        guard let stream = stream else { return }
        self.eventStream = stream

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stopFileWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    deinit {
        stop()
    }
}

// MARK: - Remote Managed Process

@available(macOS 15.0, *)
final class RemoteManagedProcess: ManagedProcess {
    private weak var client: RemoteProcessClient?
    private var watchTask: Task<Void, Never>?

    init(config: ProcessConfig, client: RemoteProcessClient) {
        self.client = client
        super.init(config: config)
        watchTask = Task { [weak self] in
            guard let self = self, let client = self.client else { return }
            await client.streamLogs(name: self.config.name) { [weak self] chunk in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.logOutput.append(chunk)
                    ManagedProcess.trimLog(&self.logOutput, maxLines: self.maxLogLines)
                }
            }
        }
    }

    override func start() {
        guard let client = client else { return }
        Task {
            do {
                try await client.start(name: config.name)
            } catch {
                await MainActor.run {
                    AppLogger.shared.log("[\(self.config.name)] start failed: \(error)")
                }
            }
        }
    }

    override func stop() {
        guard let client = client else { return }
        Task {
            do {
                try await client.stop(name: config.name)
            } catch {
                await MainActor.run {
                    AppLogger.shared.log("[\(self.config.name)] stop failed: \(error)")
                }
            }
        }
    }

    override func restart() {
        guard let client = client else { return }
        Task {
            do {
                try await client.restart(name: config.name)
            } catch {
                await MainActor.run {
                    AppLogger.shared.log("[\(self.config.name)] restart failed: \(error)")
                }
            }
        }
    }

    func applyRemoteState(_ remote: ProcessState) {
        // Preserve needsRestart locally if user marked it; otherwise mirror remote.
        if state == .needsRestart && remote == .running {
            return
        }
        state = remote
    }

    deinit {
        watchTask?.cancel()
    }
}

// MARK: - App Logger

class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published var logOutput: String = ""
    var maxLogLines: Int = Configuration.defaultMaxLogLines

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) \(message)\n"
        DispatchQueue.main.async {
            self.logOutput.append(line)
            ManagedProcess.trimLog(&self.logOutput, maxLines: self.maxLogLines)
        }
    }

    func appendRemoteSystemLog(_ chunk: String) {
        DispatchQueue.main.async {
            self.logOutput.append(chunk)
            ManagedProcess.trimLog(&self.logOutput, maxLines: self.maxLogLines)
        }
    }
}

// MARK: - Shell Environment

class ShellEnvironment {
    static let shared = ShellEnvironment()

    private(set) var environment: [String: String] = [:]
    private var searchPaths: [String] = []

    private init() {
        loadEnvironmentFromLoginShell()
    }

    private func loadEnvironmentFromLoginShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // Use NUL-delimited output so values containing newlines parse correctly.
        proc.arguments = ["-l", "-c", "/usr/bin/env -0"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let entries = text.split(separator: "\0", omittingEmptySubsequences: true)
                for entry in entries {
                    guard let eq = entry.firstIndex(of: "=") else { continue }
                    let key = String(entry[..<eq])
                    let value = String(entry[entry.index(after: eq)...])
                    environment[key] = value
                }
            }
        } catch {
            print("Failed to load environment from login shell: \(error)")
        }

        if let pathString = environment["PATH"], !pathString.isEmpty {
            searchPaths = pathString.components(separatedBy: ":")
        } else {
            searchPaths = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }
    }

    func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }
}

// MARK: - Process Supervisor

class ProcessSupervisor: ObservableObject {
    @Published var processes: [ManagedProcess] = []
    @Published var configFileURL: URL? {
        didSet {
            if let url = configFileURL {
                UserDefaults.standard.set(url.path, forKey: "configFilePath")
                loadConfiguration()
            }
        }
    }

    var hasProcessesNeedingRestart: Bool {
        processes.contains { $0.state == .needsRestart }
    }

    var hasStoppedProcesses: Bool {
        processes.contains { $0.state == .stopped }
    }

    private var cancellables = Set<AnyCancellable>()
    private var remoteClient: AnyObject?
    private var remoteRunTask: Task<Void, Never>?
    private var remotePollTask: Task<Void, Never>?
    private var remoteSystemLogTask: Task<Void, Never>?
    private var pendingRemoteTeardown: Task<Void, Never>?

    init() {
        _ = ShellEnvironment.shared

        if let savedPath = UserDefaults.standard.string(forKey: "configFilePath") {
            let url = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: savedPath) {
                self.configFileURL = url
            }
        }
    }

    func loadConfiguration() {
        guard let url = configFileURL else { return }

        do {
            let config = try Configuration.read(from: url)
            let maxLogLines = config.maxLogLines ?? Configuration.defaultMaxLogLines
            AppLogger.shared.maxLogLines = maxLogLines

            if let server = config.server, !server.isEmpty {
                if #available(macOS 15.0, *) {
                    loadRemoteConfiguration(server: server, maxLogLines: maxLogLines)
                } else {
                    AppLogger.shared.log("remote mode requires macOS 15.0+")
                }
                return
            }

            // Local mode: tear down any prior remote state.
            tearDownRemote()

            let oldProcesses = processes
            let configProcesses = config.processes ?? []
            for proc in oldProcesses {
                if !configProcesses.contains(where: { $0.name == proc.config.name }) {
                    proc.stop()
                }
            }

            var newProcesses: [ManagedProcess] = []
            for procConfig in configProcesses {
                if let existing = oldProcesses.first(where: { $0.config.name == procConfig.name && $0.config == procConfig }) {
                    newProcesses.append(existing)
                } else {
                    oldProcesses.first(where: { $0.config.name == procConfig.name })?.stop()
                    let managed = LocalManagedProcess(config: procConfig)
                    newProcesses.append(managed)
                }
            }

            for proc in newProcesses {
                proc.maxLogLines = maxLogLines
            }

            processes = newProcesses
            observeProcesses()
            startAll()
        } catch {
            print("Failed to load configuration: \(error)")
        }
    }

    @available(macOS 15.0, *)
    private func loadRemoteConfiguration(server: String, maxLogLines: Int) {
        for proc in processes {
            proc.stop()
        }
        processes = []
        observeProcesses()

        tearDownRemote()
        let priorTeardown = pendingRemoteTeardown

        let client = RemoteProcessClient(server: server)
        remoteClient = client
        AppLogger.shared.log("remote mode: connecting to \(server)")

        remoteRunTask = Task {
            await priorTeardown?.value
            await client.run()
        }

        remoteSystemLogTask = Task {
            await priorTeardown?.value
            await client.streamLogs(name: "") { chunk in
                AppLogger.shared.appendRemoteSystemLog(chunk)
            }
        }

        remotePollTask = Task { [weak self] in
            await priorTeardown?.value
            while !Task.isCancelled {
                do {
                    let statuses = try await client.fetchStatus()
                    await MainActor.run { [weak self] in
                        self?.applyRemoteStatuses(statuses, client: client, maxLogLines: maxLogLines)
                    }
                } catch {
                    await MainActor.run {
                        AppLogger.shared.log("remote status fetch failed: \(error)")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @available(macOS 15.0, *)
    private func applyRemoteStatuses(_ statuses: [RemoteProcessStatus], client: RemoteProcessClient, maxLogLines: Int) {
        var byName = [String: RemoteManagedProcess]()
        for proc in processes {
            if let remote = proc as? RemoteManagedProcess {
                byName[proc.config.name] = remote
            }
        }

        var next: [ManagedProcess] = []
        for status in statuses {
            let proc: RemoteManagedProcess
            if let existing = byName.removeValue(forKey: status.name) {
                proc = existing
            } else {
                let cfg = ProcessConfig(name: status.name, command: [], dir: "", logFile: nil, watch: nil)
                proc = RemoteManagedProcess(config: cfg, client: client)
            }
            proc.maxLogLines = maxLogLines
            proc.applyRemoteState(status.state)
            next.append(proc)
        }

        processes = next
        observeProcesses()
    }

    private func tearDownRemote() {
        let pollTask = remotePollTask
        let logTask = remoteSystemLogTask
        let runTask = remoteRunTask
        let prior = remoteClient
        remotePollTask = nil
        remoteSystemLogTask = nil
        remoteRunTask = nil
        remoteClient = nil

        pollTask?.cancel()
        logTask?.cancel()

        let priorTeardown = pendingRemoteTeardown
        pendingRemoteTeardown = Task { [pollTask, logTask, runTask, prior] in
            await priorTeardown?.value
            if #available(macOS 15.0, *), let client = prior as? RemoteProcessClient {
                await client.shutdown()
            }
            await pollTask?.value
            await logTask?.value
            await runTask?.value
        }
    }

    func startAll() {
        for proc in processes {
            if proc.state == .stopped {
                proc.start()
            }
        }
    }

    func stopAll() {
        for proc in processes {
            if #available(macOS 15.0, *), proc is RemoteManagedProcess {
                continue
            }
            proc.stop()
        }
    }

    func restartNeedingRestart() {
        for proc in processes where proc.state == .needsRestart {
            proc.restart()
        }
    }

    private func observeProcesses() {
        cancellables.removeAll()
        for proc in processes {
            proc.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    deinit {
        stopAll()
        tearDownRemote()
    }
}
