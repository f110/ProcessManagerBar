import XCTest
@testable import ProcessManagerBar

class ConfigurationTest: XCTestCase {
    func testRead() throws {
        let yaml = """
        processes:
          - name: web-server
            command: go run ./cmd/server
            dir: /tmp/myproject
          - name: worker
            command: python worker.py
            dir: /tmp/worker
        """

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-config.yaml")
        try yaml.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let config = try Configuration.read(from: tempFile)
        XCTAssertEqual(config.processes.count, 2)
        XCTAssertEqual(config.processes[0].name, "web-server")
        XCTAssertEqual(config.processes[0].command, "go run ./cmd/server")
        XCTAssertEqual(config.processes[0].dir, "/tmp/myproject")
        XCTAssertEqual(config.processes[1].name, "worker")
        XCTAssertEqual(config.processes[1].command, "python worker.py")
        XCTAssertEqual(config.processes[1].dir, "/tmp/worker")
    }
}
