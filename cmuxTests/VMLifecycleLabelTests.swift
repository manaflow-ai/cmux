import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testVMLifecycleResolvesDisplayNameAfterBackendNotFound() throws {
        let (result, requests) = try runVMLifecycleLabelFixture()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OK probe-a resumed (status=running)"), result.stdout)
        XCTAssertEqual(requests.map(\.method), ["vm.resume", "vm.list", "vm.resume"])
        XCTAssertEqual(requests.map(\.target), ["probe-a", "", "vm-label-fixture"])
    }

    func testVMLifecycleResolvesSlugForEveryLifecycleAction() throws {
        for action in ["pause", "resume", "restart"] {
            let (result, requests) = try runVMLifecycleLabelFixture(
                action: action,
                selector: "sleepy-teal-otter",
                json: true
            )
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(requests.map(\.method), ["vm.\(action)", "vm.list", "vm.\(action)"])
            XCTAssertEqual(requests.last?.target, "vm-label-fixture")
            let payload = jsonObject(result.stdout)
            XCTAssertEqual(payload?["id"] as? String, "vm-label-fixture", result.stdout)
            XCTAssertEqual(payload?["status"] as? String, action == "pause" ? "paused" : "running")
        }
    }

    func testVMLifecycleQuotesLabelsInResumeGuidance() throws {
        let selector = "My Build Box's $(echo unexpected)"
        let (result, requests) = try runVMLifecycleLabelFixture(
            action: "pause",
            selector: selector,
            machines: [["id": "vm-label-fixture", "displayName": selector]]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OK \(selector) paused (status=paused)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux vm resume 'My Build Box'\"'\"'s $(echo unexpected)'"), result.stdout)
        XCTAssertEqual(requests.last?.target, "vm-label-fixture")
    }

    func testVMLifecycleUsesCanonicalIDWithoutListRequest() throws {
        let (result, requests) = try runVMLifecycleLabelFixture(
            selector: "vm-label-fixture", directSuccess: true
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(requests.map(\.method), ["vm.resume"])
        XCTAssertEqual(requests.first?.target, "vm-label-fixture")
    }

    func testVMLifecycleRejectsAmbiguousLabelsBeforeRetry() throws {
        for machines in [
            [["id": "vm-one", "displayName": "probe-a"], ["id": "vm-two", "displayName": "probe-a"]],
            [["id": "vm-one", "displayName": "probe-a"], ["id": "vm-two", "slug": "probe-a"]],
        ] {
            let (result, requests) = try runVMLifecycleLabelFixture(machines: machines)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("probe-a"), result.stderr)
            XCTAssertTrue(result.stderr.contains("matches multiple machines"), result.stderr)
            XCTAssertEqual(requests.map(\.method), ["vm.resume", "vm.list"])
        }
    }

    func testVMLifecycleDoesNotRetargetAnExactIDMatchingAnotherLabel() throws {
        let (result, requests) = try runVMLifecycleLabelFixture(machines: [
            ["id": "vm-other", "displayName": "probe-a"],
            ["id": "probe-a", "displayName": "My VM"],
        ])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("original lifecycle failure"), result.stderr)
        XCTAssertEqual(requests.map(\.method), ["vm.resume", "vm.list"])
    }

    func testVMLifecyclePreservesMissingAndUnavailableListFailures() throws {
        for listFails in [false, true] {
            let (result, requests) = try runVMLifecycleLabelFixture(machines: [], listFails: listFails)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("original lifecycle failure"), result.stderr)
            XCTAssertEqual(requests.map(\.method), ["vm.resume", "vm.list"])
        }
    }

    func testVMLifecycleDoesNotRetryOtherBackendErrors() throws {
        for (code, status) in [("vm_operation_in_progress", 503), ("vm_cloud_service_unavailable", 502),
                               ("provider_resource_not_found", 404)] {
            let (result, requests) = try runVMLifecycleLabelFixture(errorCode: code, httpStatus: status)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertEqual(requests.map(\.method), ["vm.resume"])
        }
    }

    private func runVMLifecycleLabelFixture(
        action: String = "resume",
        selector: String = "probe-a",
        machines: [[String: String]] = [[
            "id": "vm-label-fixture", "displayName": "probe-a", "slug": "sleepy-teal-otter",
        ]],
        directSuccess: Bool = false,
        json: Bool = false,
        errorCode: String = "vm_not_found",
        httpStatus: Int = 404,
        listFails: Bool = false
    ) throws -> (ProcessRunResult, [(method: String, target: String)]) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-label")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-label-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: home)
        }
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            if method == "vm.list" {
                if listFails {
                    return self.v2Response(id: id, ok: false, error: ["code": "list_unavailable", "message": "list unavailable"])
                }
                return self.v2Response(id: id, ok: true, result: ["vms": machines])
            }
            guard method == "vm.\(action)" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            let target = (payload["params"] as? [String: Any])?["id"] as? String ?? ""
            if directSuccess || target != selector {
                return self.v2Response(id: id, ok: true, result: ["id": target, "status": action == "pause" ? "paused" : "running"])
            }
            return self.v2Response(id: id, ok: false, error: [
                "code": "backend_error", "message": "original lifecycle failure",
                "data": ["backend_code": errorCode, "http_status": httpStatus],
            ])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(en)"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", action, selector] + (json ? ["--json"] : []),
            environment: environment,
            timeout: 10
        )
        wait(for: [serverHandled], timeout: 10)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        let requests = state.snapshot().compactMap { line -> (method: String, target: String)? in
            guard let request = self.jsonObject(line), let method = request["method"] as? String else { return nil }
            return (method, (request["params"] as? [String: Any])?["id"] as? String ?? "")
        }
        return (result, requests)
    }
}
