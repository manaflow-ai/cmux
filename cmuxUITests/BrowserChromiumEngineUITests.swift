import XCTest
import Foundation
import AppKit

final class BrowserChromiumEngineUITests: XCTestCase {
    private enum TestFailure: Error {
        case invalidResponse(String)
    }

    private let launchTag = "chromui"
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var screenshotPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-chromium-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-chromium-\(UUID().uuidString).json"
        screenshotPath = "/tmp/cmux-ui-test-chromium-\(UUID().uuidString).png"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: screenshotPath)
    }

    func testChromiumEngineRendersAndHandlesBrowserAutomation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAndAllowHeadlessActivation(app)
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(atPath: self.socketPath)
            try? FileManager.default.removeItem(atPath: self.diagnosticsPath)
        }

        XCTAssertTrue(
            waitForSocketReady(timeout: 60.0),
            "Expected cmux control socket to accept v2 requests. candidates=\(socketCandidates()) diagnostics=\(loadJSON(atPath: diagnosticsPath) ?? [:])"
        )

        let openResult = try okResult(
            socketJSON(
                method: "browser.open_split",
                params: [
                    "url": proofPageURL(),
                    "focus": false,
                ],
                responseTimeout: 45.0
            )
        )

        guard let surfaceId = openResult["surface_id"] as? String, !surfaceId.isEmpty else {
            XCTFail("browser.open_split did not return a surface_id: \(openResult)")
            throw TestFailure.invalidResponse("missing surface_id")
        }
        guard let engine = openResult["engine"] as? [String: Any] else {
            XCTFail("browser.open_split did not return engine metadata: \(openResult)")
            throw TestFailure.invalidResponse("missing engine")
        }

        XCTAssertEqual(engine["kind"] as? String, "chromium")
        XCTAssertEqual(engine["chromium_ready"] as? Bool, true)
        XCTAssertEqual(engine["chromium_sandbox_disabled"] as? Bool, false)
        XCTAssertEqual(engine["chromium_uses_in_process_gpu_by_default"] as? Bool, false)
        XCTAssertEqual(engine["host_class_name"] as? String, "CmuxChromiumBrowserHost")
        XCTAssertEqual(engine["chromium_compositor_layer"] as? String, "CALayerHost")
        XCTAssertEqual(engine["chromium_surface_transport"] as? String, "IOSurface/Metal")
        XCTAssertTrue(
            ((engine["resources"] as? [String]) ?? []).contains("libowl_fresh_mojo_runtime.dylib"),
            "Expected OWL Fresh Chromium runtime to be embedded: \(engine)"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["BrowserChromiumSurface"].waitForExistence(timeout: 10.0),
            "Expected the Chromium NSViewRepresentable surface to be present"
        )

        _ = try okResult(
            socketJSON(
                method: "browser.wait",
                params: [
                    "surface_id": surfaceId,
                    "text_contains": "Chromium cmux proof",
                    "timeout_ms": 10_000,
                ],
                responseTimeout: 20.0
            )
        )

        let titleResult = try okResult(
            socketJSON(
                method: "browser.eval",
                params: [
                    "surface_id": surfaceId,
                    "script": "document.title",
                ]
            )
        )
        XCTAssertEqual(titleResult["value"] as? String, "cmux chromium ui")

        let snapshotResult = try okResult(
            socketJSON(
                method: "browser.snapshot",
                params: ["surface_id": surfaceId],
                responseTimeout: 20.0
            )
        )
        let snapshot = snapshotResult["snapshot"] as? String ?? ""
        XCTAssertTrue(snapshot.contains("Chromium cmux proof"), snapshot)
        XCTAssertEqual((snapshotResult["engine"] as? [String: Any])?["kind"] as? String, "chromium")

        _ = try okResult(
            socketJSON(
                method: "browser.click",
                params: [
                    "surface_id": surfaceId,
                    "selector": "#ok",
                ]
            )
        )

        let clickResult = try okResult(
            socketJSON(
                method: "browser.eval",
                params: [
                    "surface_id": surfaceId,
                    "script": "document.body.dataset.clicked",
                ]
            )
        )
        XCTAssertEqual(clickResult["value"] as? String, "yes")

        let screenshotResult = try okResult(
            socketJSON(
                method: "browser.screenshot",
                params: ["surface_id": surfaceId],
                responseTimeout: 30.0
            )
        )
        guard let pngBase64 = screenshotResult["png_base64"] as? String,
              let pngData = Data(base64Encoded: pngBase64) else {
            XCTFail("browser.screenshot did not return valid PNG data: \(screenshotResult)")
            throw TestFailure.invalidResponse("invalid png")
        }
        XCTAssertEqual(Array(pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard let image = NSImage(data: pngData) else {
            XCTFail("browser.screenshot returned undecodable PNG data")
            throw TestFailure.invalidResponse("undecodable png")
        }
        XCTAssertGreaterThan(image.size.width, 10)
        XCTAssertGreaterThan(image.size.height, 10)
        try pngData.write(to: URL(fileURLWithPath: screenshotPath), options: .atomic)
        let attachment = XCTAttachment(data: pngData, uniformTypeIdentifier: "public.png")
        attachment.name = "Chromium browser surface screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let path = screenshotResult["path"] as? String {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Expected screenshot file to exist at \(path)")
        }
    }

    private func proofPageURL() -> String {
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>cmux chromium ui</title>
            <style>
              body { margin: 0; background: #f6f7f9; color: #172026; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
              main { padding: 48px; }
              h1 { margin: 0 0 12px; font-size: 34px; }
              p { font-size: 18px; }
              button { margin-top: 18px; padding: 12px 18px; font-size: 17px; border-radius: 6px; border: 1px solid #172026; background: #ffffff; }
            </style>
          </head>
          <body>
            <main>
              <h1>Chromium cmux proof</h1>
              <p id="marker">CALayerHost Chromium browser surface</p>
              <button id="ok" onclick="document.body.dataset.clicked='yes';this.textContent='clicked';">click proof</button>
            </main>
          </body>
        </html>
        """
        return "data:text/html;base64,\(Data(html.utf8).base64EncodedString())"
    }

    private func launchAndAllowHeadlessActivation(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground || app.state == .runningBackground {
            return
        }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func waitForSocketReady(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let completed = waitForCondition(timeout: timeout) {
            let originalPath = self.socketPath
            for candidate in self.socketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                self.socketPath = candidate
                if self.socketV2Ready(responseTimeout: 3.0) {
                    resolvedPath = candidate
                    return true
                }
                self.socketPath = originalPath
            }
            return false
        }
        if let resolvedPath {
            socketPath = resolvedPath
        }
        return completed
    }

    private func socketV2Ready(responseTimeout: TimeInterval) -> Bool {
        let ping = socketJSON(method: "system.ping", params: [:], responseTimeout: responseTimeout)
        let pingResult = ping?["result"] as? [String: Any]
        if (ping?["ok"] as? Bool) == true, pingResult?["pong"] as? Bool == true {
            return true
        }

        let capabilities = socketJSON(method: "system.capabilities", params: [:], responseTimeout: responseTimeout)
        let capabilitiesResult = capabilities?["result"] as? [String: Any]
        let methods = capabilitiesResult?["methods"] as? [String] ?? []
        return (capabilities?["ok"] as? Bool) == true && methods.contains("browser.open_split")
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0).inserted }
        return candidates
    }

    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json
    }

    private func socketJSON(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 12.0
    ) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendJSON(request)
    }

    private func okResult(
        _ envelope: [String: Any]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        guard let envelope else {
            XCTFail("Missing socket response", file: file, line: line)
            throw TestFailure.invalidResponse("missing response")
        }
        guard (envelope["ok"] as? Bool) == true else {
            XCTFail("Socket request failed: \(envelope)", file: file, line: line)
            throw TestFailure.invalidResponse("not ok")
        }
        guard let result = envelope["result"] as? [String: Any] else {
            XCTFail("Socket response did not contain a result object: \(envelope)", file: file, line: line)
            throw TestFailure.invalidResponse("missing result")
        }
        return result
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }
            return parsed
        }

        func sendLine(_ line: String) -> String? {
            if let response = sendLineViaSocket(line) {
                return response
            }
            return sendLineViaNetcat(line)
        }

        private func sendLineViaSocket(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var socketTimeout = timeval(
                tv_sec: Int(responseTimeout.rounded(.down)),
                tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
            )

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            let deadline = Date().addingTimeInterval(responseTimeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while Date() < deadline {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    return nil
                }
                if ready == 0 {
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func sendLineViaNetcat(_ line: String) -> String? {
            let nc = "/usr/bin/nc"
            guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
            proc.arguments = [
                "-lc",
                "printf '%s\\n' \(shellSingleQuote(line)) | \(nc) -U \(shellSingleQuote(path)) -w \(timeoutSeconds) 2>/dev/null",
            ]

            let outPipe = Pipe()
            proc.standardOutput = outPipe

            do {
                try proc.run()
            } catch {
                return nil
            }

            proc.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
            let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func shellSingleQuote(_ value: String) -> String {
            if value.isEmpty { return "''" }
            return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
    }
}
