import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

struct RemoteProcessStatus {
    let name: String
    let state: ProcessState
}

@available(macOS 15.0, *)
final class RemoteProcessClient {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private let processClient: Process_ProcessManager.Client<HTTP2ClientTransport.Posix>?

    init(server: String) {
        if let transport = Self.makeTransport(server: server) {
            let g = GRPCClient(transport: transport)
            self.grpcClient = g
            self.processClient = Process_ProcessManager.Client(wrapping: g)
        } else {
            self.grpcClient = nil
            self.processClient = nil
        }
    }

    private static func makeTransport(server: String) -> HTTP2ClientTransport.Posix? {
        do {
            if server.hasPrefix("unix://") {
                let path = String(server.dropFirst("unix://".count))
                return try HTTP2ClientTransport.Posix(
                    target: .unixDomainSocket(path: path),
                    transportSecurity: .plaintext
                )
            }
            let stripped: String
            if server.hasPrefix("tcp://") {
                stripped = String(server.dropFirst("tcp://".count))
            } else {
                stripped = server
            }
            let parts = stripped.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let port = Int(parts[1]) else { return nil }
            return try HTTP2ClientTransport.Posix(
                target: .dns(host: parts[0], port: port),
                transportSecurity: .plaintext
            )
        } catch {
            return nil
        }
    }

    func run() async {
        guard let g = grpcClient else { return }
        do {
            try await g.runConnections()
        } catch {
            AppLogger.shared.log("gRPC connection error: \(error)")
        }
    }

    func shutdown() async {
        grpcClient?.beginGracefulShutdown()
    }

    func fetchStatus() async throws -> [RemoteProcessStatus] {
        guard let p = processClient else { return [] }
        let response = try await p.status(Process_RequestStatus())
        return response.processes.map { item in
            let state: ProcessState
            switch item.state {
            case .running: state = .running
            case .stop: state = .stopped
            case .needsRestart: state = .needsRestart
            default: state = .stopped
            }
            return RemoteProcessStatus(name: item.name, state: state)
        }
    }

    func start(name: String) async throws {
        guard let p = processClient else { return }
        var req = Process_RequestStart()
        req.name = name
        _ = try await p.start(req)
    }

    func stop(name: String) async throws {
        guard let p = processClient else { return }
        var req = Process_RequestStop()
        req.name = name
        _ = try await p.stop(req)
    }

    func restart(name: String) async throws {
        guard let p = processClient else { return }
        var req = Process_RequestRestart()
        req.name = name
        _ = try await p.restart(req)
    }

    func streamStatus(_ handler: @Sendable @escaping ([RemoteProcessStatus]) -> Void) async {
        guard let p = processClient else { return }
        let req = Process_RequestWatchStatus()
        do {
            try await p.watchStatus(req) { response in
                for try await message in response.messages {
                    let statuses = message.processes.map { item -> RemoteProcessStatus in
                        let state: ProcessState
                        switch item.state {
                        case .running: state = .running
                        case .stop: state = .stopped
                        case .needsRestart: state = .needsRestart
                        default: state = .stopped
                        }
                        return RemoteProcessStatus(name: item.name, state: state)
                    }
                    handler(statuses)
                }
            }
        } catch {
            // Stream ended or transport error; let caller decide whether to retry.
        }
    }

    func streamLogs(name: String, _ handler: @Sendable @escaping (String) -> Void) async {
        guard let p = processClient else { return }
        var req = Process_RequestWatchLogs()
        req.name = name
        do {
            try await p.watchLogs(req) { response in
                for try await message in response.messages {
                    if let s = String(data: message.content, encoding: .utf8) {
                        handler(s)
                    }
                }
            }
        } catch {
            // Stream ended or transport error; let caller decide whether to retry.
        }
    }
}
