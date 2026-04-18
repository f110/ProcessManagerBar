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

    private var process: Process?
    private var logFileHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var eventStream: FSEventStreamRef?
    private var isRestarting = false

    private static let ignoredDirNames: Set<String> = [
        ".git", "node_modules", "vendor", ".build", "__pycache__", ".svn", ".hg",
    ]

    init(config: ProcessConfig) {
        self.config = config
    }

    func start() {
        guard state != .running else { return }

        guard !config.command.isEmpty else {
            state = .error("コマンドが指定されていません")
            return
        }

        let executable = config.command[0]
        let resolvedPath: String

        if executable.contains("/") {
            // Absolute or relative path — use as-is
            let fullPath = executable.hasPrefix("/")
                ? executable
                : (config.dir as NSString).appendingPathComponent(executable)
            guard FileManager.default.isExecutableFile(atPath: fullPath) else {
                state = .error("実行ファイルが見つかりません: \(executable)")
                return
            }
            resolvedPath = fullPath
        } else {
            // Look up in PATH
            guard let found = ShellEnvironment.shared.resolveExecutable(executable) else {
                state = .error("実行ファイルが見つかりません: \(executable)")
                return
            }
            resolvedPath = found
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedPath)
        proc.arguments = Array(config.command.dropFirst())
        proc.currentDirectoryURL = URL(fileURLWithPath: config.dir)

        // Set up log file if configured
        if let logPath = config.logFile {
            let expandedPath = NSString(string: logPath).expandingTildeInPath
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

        // Capture stdout and stderr via pipes
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
                self?.logOutput.append(text)
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
                    self.isRestarting = false
                    self.state = .stopped
                    self.start()
                    return
                }
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
            // 子プロセスをアプリと同じプロセスグループに移動する
            let childPid = proc.processIdentifier
            let myPgid = getpgrp()
            setpgid(childPid, myPgid)
            self.process = proc
            state = .running
            startFileWatching()
        } catch {
            state = .error("起動失敗: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopFileWatching()
        guard let proc = process, proc.isRunning else {
            state = .stopped
            return
        }
        terminateProcess(proc)
    }

    func restart() {
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

    func markNeedsRestart() {
        if state == .running {
            state = .needsRestart
        }
    }

    // MARK: - File Watching (FSEvents)

    private func startFileWatching() {
        stopFileWatching()

        let pathToWatch = config.dir as CFString
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
            let process = Unmanaged<ManagedProcess>.fromOpaque(info).takeUnretainedValue()

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

// MARK: - Shell Environment

class ShellEnvironment {
    static let shared = ShellEnvironment()

    private var searchPaths: [String] = []

    private init() {
        loadPathFromLoginShell()
    }

    private func loadPathFromLoginShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "echo $PATH"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let pathString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pathString.isEmpty {
                searchPaths = pathString.components(separatedBy: ":")
            }
        } catch {
            print("Failed to load PATH from login shell: \(error)")
        }

        // Fallback if empty
        if searchPaths.isEmpty {
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

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Trigger ShellEnvironment initialization early
        _ = ShellEnvironment.shared

        if let savedPath = UserDefaults.standard.string(forKey: "configFilePath") {
            let url = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: savedPath) {
                self.configFileURL = url
                loadConfiguration()
            }
        }
    }

    func loadConfiguration() {
        guard let url = configFileURL else { return }

        do {
            let config = try Configuration.read(from: url)
            let oldProcesses = processes
            for proc in oldProcesses {
                if !config.processes.contains(where: { $0.name == proc.config.name }) {
                    proc.stop()
                }
            }

            var newProcesses: [ManagedProcess] = []
            for procConfig in config.processes {
                if let existing = oldProcesses.first(where: { $0.config.name == procConfig.name && $0.config == procConfig }) {
                    newProcesses.append(existing)
                } else {
                    oldProcesses.first(where: { $0.config.name == procConfig.name })?.stop()
                    let managed = ManagedProcess(config: procConfig)
                    newProcesses.append(managed)
                }
            }

            processes = newProcesses
            observeProcesses()
            startAll()
        } catch {
            print("Failed to load configuration: \(error)")
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
    }
}
