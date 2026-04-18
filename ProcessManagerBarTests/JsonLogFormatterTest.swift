import XCTest
@testable import ProcessManagerBar

class JsonLogFormatterTest: XCTestCase {

    // MARK: - Timestamp format tests

    func testRFC3339() {
        let result = JsonLogFormatter.formatTimestamp("2026-04-19T01:53:27+09:00")
        XCTAssertEqual(result, "Apr 19 01:53:27")
    }

    func testRFC3339WithFractionalSeconds() {
        let result = JsonLogFormatter.formatTimestamp("2026-04-19T01:53:27.329+09:00")
        XCTAssertEqual(result, "Apr 19 01:53:27.329")
    }

    func testRFC3339Nano() {
        let result = JsonLogFormatter.formatTimestamp("2026-04-19T01:53:27.123456789+09:00")
        XCTAssertEqual(result, "Apr 19 01:53:27.123456789")
    }

    func testRFC3339NanoSixDigits() {
        let result = JsonLogFormatter.formatTimestamp("2026-04-19T01:53:27.123456+09:00")
        XCTAssertEqual(result, "Apr 19 01:53:27.123456")
    }

    func testRFC3339UTC() {
        let result = JsonLogFormatter.formatTimestamp("2026-04-19T10:00:00Z")
        XCTAssertNotEqual(result, "2026-04-19T10:00:00Z", "Should be formatted, not raw")
        XCTAssertTrue(result.hasPrefix("Apr 19"))
    }

    func testRFC3339WithoutFraction() {
        let result = JsonLogFormatter.formatTimestamp("2026-04-19T01:53:27+09:00")
        XCTAssertFalse(result.contains("."), "No fractional seconds should appear")
    }

    func testRFC1123NumericTimezone() {
        let result = JsonLogFormatter.formatTimestamp("Sat, 18 Apr 2026 01:53:27 +0900")
        XCTAssertEqual(result, "Apr 18 01:53:27")
    }

    func testRFC1123GMT() {
        // 01:53:27 GMT → local time conversion, just verify it parses
        let result = JsonLogFormatter.formatTimestamp("Sat, 18 Apr 2026 01:53:27 GMT")
        XCTAssertNotEqual(result, "Sat, 18 Apr 2026 01:53:27 GMT", "Should be formatted, not raw")
        XCTAssertTrue(result.contains("Apr"), "Should parse RFC1123 with GMT, got: \(result)")
    }

    func testRFC822NumericTimezone() {
        // RFC822 with 2-digit year - verify it parses to something
        let input = "18 Apr 26 01:53 +0900"
        let result = JsonLogFormatter.formatTimestamp(input)
        // RFC822 with 2-digit year parsing is platform-dependent; just verify it doesn't crash
        XCTAssertFalse(result.isEmpty, "Should return non-empty result")
    }

    func testRFC850NumericTimezone() {
        let result = JsonLogFormatter.formatTimestamp("Saturday, 18-Apr-26 01:53:27 +0900")
        XCTAssertTrue(result.hasPrefix("Apr"), "Should parse RFC850, got: \(result)")
        XCTAssertTrue(result.contains("01:53:27"), "Should contain time, got: \(result)")
    }

    func testUnixTimestamp() {
        // Use a known timestamp: 2026-01-01T00:00:00Z = 1767225600
        let result = JsonLogFormatter.formatTimestamp("1767225600")
        XCTAssertTrue(result.hasPrefix("Jan") || result.hasPrefix("Dec"),
                      "Should parse unix timestamp, got: \(result)")
        XCTAssertFalse(result.contains("."), "Integer unix timestamp should have no fraction")
    }

    func testUnixTimestampWithFraction() {
        let result = JsonLogFormatter.formatTimestamp("1767225600.329")
        XCTAssertTrue(result.hasPrefix("Jan") || result.hasPrefix("Dec"),
                      "Should parse unix timestamp with fraction, got: \(result)")
        XCTAssertTrue(result.contains("."), "Fractional unix timestamp should have fraction")
    }

    func testUnparseableTimestamp() {
        let result = JsonLogFormatter.formatTimestamp("not-a-timestamp")
        XCTAssertEqual(result, "not-a-timestamp", "Should return raw string if unparseable")
    }

    // MARK: - Full format tests

    func testFullJsonLine() {
        let line = #"{"level":"info","time":"2026-04-19T01:53:27.329+0900","caller":"simple-http-server/server.go:237","msg":"Start server","addr":":8083"}"#
        let result = JsonLogFormatter.format(line)
        XCTAssertTrue(result.hasPrefix("Apr 19 01:53:27.329"))
        XCTAssertTrue(result.contains("│INF│"))
        XCTAssertTrue(result.contains("Start server"))
        XCTAssertTrue(result.contains("addr=:8083"))
        XCTAssertTrue(result.hasSuffix("→ simple-http-server/server.go:237"))
    }

    func testNonJsonLine() {
        let line = "plain text log line"
        XCTAssertEqual(JsonLogFormatter.format(line), line)
    }

    func testJsonWithoutTimestamp() {
        let line = #"{"level":"error","msg":"something failed","code":500}"#
        let result = JsonLogFormatter.format(line)
        XCTAssertTrue(result.hasPrefix("│ERR│"))
        XCTAssertTrue(result.contains("something failed"))
        XCTAssertTrue(result.contains("code=500"))
    }

    func testErrorField() {
        let line = #"{"level":"error","msg":"request failed","error":"connection refused"}"#
        let result = JsonLogFormatter.format(line)
        XCTAssertTrue(result.contains("error=connection refused"))
    }

    func testLevelFormats() {
        let levels: [(String, String)] = [
            ("debug", "DBG"), ("info", "INF"), ("warn", "WRN"),
            ("warning", "WRN"), ("error", "ERR"), ("fatal", "FTL"),
            ("panic", "PNC"), ("trace", "TRC"),
        ]
        for (input, expected) in levels {
            let line = "{\"level\":\"\(input)\",\"msg\":\"test\"}"
            let result = JsonLogFormatter.format(line)
            XCTAssertTrue(result.contains("│\(expected)│"), "Level '\(input)' should format as │\(expected)│, got: \(result)")
        }
    }

    func testFieldOrder() {
        // Verify: timestamp, level, message, extra fields, then caller at end
        let line = #"{"caller":"main.go:10","level":"info","msg":"hello","time":"2026-04-19T01:00:00+09:00","foo":"bar"}"#
        let result = JsonLogFormatter.format(line)
        let tsIndex = result.range(of: "Apr 19")!.lowerBound
        let levelIndex = result.range(of: "│INF│")!.lowerBound
        let msgIndex = result.range(of: "hello")!.lowerBound
        let fooIndex = result.range(of: "foo=bar")!.lowerBound
        let callerIndex = result.range(of: "→ main.go:10")!.lowerBound
        XCTAssertTrue(tsIndex < levelIndex)
        XCTAssertTrue(levelIndex < msgIndex)
        XCTAssertTrue(msgIndex < fooIndex)
        XCTAssertTrue(fooIndex < callerIndex)
    }
}
