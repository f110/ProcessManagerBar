import Foundation
import Yams

struct ProcessConfig: Codable, Identifiable, Equatable {
    var name: String
    var command: [String]
    var dir: String
    var logFile: String?
    var watch: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, command, dir, watch
        case logFile = "log_file"
    }
}

extension ProcessConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent([String].self, forKey: .command) ?? []
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile)
        watch = try c.decodeIfPresent(Bool.self, forKey: .watch)
    }
}

struct LinkConfig: Codable, Identifiable, Equatable {
    var name: String
    var url: String

    var id: String { name }
}

struct Configuration: Codable {
    var processes: [ProcessConfig]?
    var maxLogLines: Int?
    var server: String?
    var links: [LinkConfig]?

    enum CodingKeys: String, CodingKey {
        case processes
        case maxLogLines = "max_log_lines"
        case server
        case links
    }

    static let defaultMaxLogLines = 1000

    static func read(from url: URL) throws -> Configuration {
        let data = try String(contentsOf: url, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(Configuration.self, from: data)
    }
}
