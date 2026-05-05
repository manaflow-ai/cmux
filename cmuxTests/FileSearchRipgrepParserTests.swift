import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileSearchRipgrepParserTests: XCTestCase {
    func testParseMatchLineBuildsRelativeSearchResult() {
        let line = """
        {"type":"match","data":{"path":{"text":"/tmp/project/Sources/App.swift"},"lines":{"text":"let title = \\"Search files\\"\\n"},"line_number":42,"submatches":[{"match":{"text":"Search"},"start":13,"end":19}]}}
        """

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/tmp/project/Sources/App.swift")
        XCTAssertEqual(result?.relativePath, "Sources/App.swift")
        XCTAssertEqual(result?.lineNumber, 42)
        XCTAssertEqual(result?.columnNumber, 14)
        XCTAssertEqual(result?.preview, "let title = \"Search files\"")
    }

    func testParseMatchLineAcceptsBytesPayloads() throws {
        let line = try makeMatchLine(
            pathPayload: [
                "bytes": Data("/tmp/project/Sources/Bytes.swift".utf8).base64EncodedString(),
            ],
            linesPayload: [
                "bytes": Data("let title = \"Search files\"\n".utf8).base64EncodedString(),
            ]
        )

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/tmp/project/Sources/Bytes.swift")
        XCTAssertEqual(result?.relativePath, "Sources/Bytes.swift")
        XCTAssertEqual(result?.lineNumber, 7)
        XCTAssertEqual(result?.columnNumber, 5)
        XCTAssertEqual(result?.preview, "let title = \"Search files\"")
    }

    func testParseMatchLineMapsInvalidUtf8BytesPayloads() throws {
        let line = try makeMatchLine(
            pathPayload: [
                "bytes": Data("/tmp/project/Sources/Invalid.swift".utf8).base64EncodedString(),
            ],
            linesPayload: [
                "bytes": Data([0x20, 0x66, 0x6f, 0x80, 0x6f, 0x0a] as [UInt8]).base64EncodedString(),
            ]
        )

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/tmp/project/Sources/Invalid.swift")
        XCTAssertEqual(result?.relativePath, "Sources/Invalid.swift")
        XCTAssertEqual(result?.preview.unicodeScalars.map(\.value), [102, 111, 65_533, 111])
    }

    func testParseMatchLineIgnoresNonMatchEvents() {
        let line = #"{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":1}}}"#

        XCTAssertNil(FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project"))
    }

    private func makeMatchLine(
        pathPayload: [String: Any],
        linesPayload: [String: Any]
    ) throws -> String {
        let object: [String: Any] = [
            "type": "match",
            "data": [
                "path": pathPayload,
                "lines": linesPayload,
                "line_number": 7,
                "submatches": [
                    [
                        "match": ["text": "title"],
                        "start": 4,
                        "end": 9,
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
