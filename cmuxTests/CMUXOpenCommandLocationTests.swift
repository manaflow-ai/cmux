import Darwin
import Foundation
import XCTest

extension CMUXOpenCommandTests {
    func testOpenCommandNormalizesPathLocationAndLocalFileURL() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-location")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("src", isDirectory: true)
        let locationFileURL = sourceURL.appendingPathComponent("main.swift")
        let fileURL = rootURL.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try "print(\"hello\")\n".write(to: locationFileURL, atomically: true, encoding: .utf8)
        try "notes\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "file.open" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            guard params["paths"] as? [String] == [locationFileURL.path, fileURL.path] else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-file-paths"])
            }
            return Self.v2Response(id: id, ok: true, result: [
                "surface_id": "surface-id",
                "pane_id": "pane-id",
            ])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", "src/main.swift:42", fileURL.absoluteString],
            currentDirectoryURL: rootURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK files=2 surface=surface-id pane=pane-id\n")
    }

}
