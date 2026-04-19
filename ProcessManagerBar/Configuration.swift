import Foundation
import Yams

struct ProcessConfig: Codable, Identifiable, Equatable {
    var name: String
    var command: [String]
    var dir: String
    var logFile: String?
    var jsonLog: Bool?
    var watch: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, command, dir, watch
        case logFile = "log_file"
        case jsonLog = "json_log"
    }
}

struct Configuration: Codable {
    var processes: [ProcessConfig]

    static func read(from url: URL) throws -> Configuration {
        let data = try String(contentsOf: url, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(Configuration.self, from: data)
    }
}
