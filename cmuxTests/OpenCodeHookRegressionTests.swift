import CmuxFoundation
import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class OpenCodeHookRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    func testOpenCodeLifecycleHookDeliveryDoesNotBlockOnCmuxProcessExit() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "cat >/dev/null",
            "/usr/bin/nc -U \"$TEST_HOOK_RELEASE_SOCKET\" >/dev/null",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let releaseSocket = fixture.root.appendingPathComponent("release.sock", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_RELEASE_SOCKET"] = releaseSocket.path
        let harness = fixture.root.appendingPathComponent("nonblocking.mjs", isDirectory: false)
        try """
        import net from "node:net";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));
        let releaseHook;
        const hookConnected = new Promise((resolve) => { releaseHook = resolve; });
        const releaseServer = net.createServer((socket) => releaseHook(socket));
        await new Promise((resolve, reject) => {
          releaseServer.once("error", reject);
          releaseServer.listen(process.env.TEST_HOOK_RELEASE_SOCKET, resolve);
        });
        const hooks = await plugin({ directory: process.cwd() });
        let eventReturned = false;
        const eventDelivery = hooks.event({ event: {
          type: "session.created",
          properties: { info: { id: "session-nonblocking", directory: process.cwd() } },
        } }).then(() => { eventReturned = true; });
        const heldHook = await hookConnected;
        const returnedBeforeRelease = eventReturned;
        heldHook.end("release\\n");
        await eventDelivery;
        await new Promise((resolve) => releaseServer.close(resolve));
        console.log(JSON.stringify({ returnedBeforeRelease }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Bool]
        )
        XCTAssertEqual(output["returnedBeforeRelease"], true)
    }

    func testOpenCodeSessionUpdatedDoesNotRepeatSessionStartHook() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "printf '%s\\n' \"$*\" >> \"$TEST_HOOK_CAPTURE\"",
            "cat >/dev/null",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path

        let harness = fixture.root.appendingPathComponent("dedupe.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));
        const hooks = await plugin({ directory: process.cwd() });
        const info = { id: "session-dedupe", directory: process.cwd() };
        await hooks.event({ event: { type: "session.created", properties: { info } } });
        await hooks.event({ event: { type: "session.updated", properties: { info } } });
        await hooks.event({ event: { type: "session.updated", properties: { info } } });
        await hooks.event({ event: { type: "session.updated", properties: { info } } });
        await new Promise((resolve, reject) => {
          if (fs.existsSync(process.env.TEST_HOOK_CAPTURE)) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!fs.existsSync(process.env.TEST_HOOK_CAPTURE)) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error("hook capture was not created"));
          }, 2000);
        });
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let invocations = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.contains("hooks opencode session-start") }
        XCTAssertEqual(invocations.count, 1, "session.updated repeated session-start: \(invocations)")
    }

    func testOpenCodeLifecycleHooksStayOrderedPerSessionWhileOtherSessionsDispatch() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "case \"$payload\" in",
            "  *session-ordered*)",
            "    cat \"$TEST_HOOK_RELEASE_FIFO\" >/dev/null",
            "    ;;",
            "esac",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseFIFO = fixture.root.appendingPathComponent("release.fifo", isDirectory: false)
        XCTAssertEqual(mkfifo(releaseFIFO.path, S_IRUSR | S_IWUSR), 0)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_FIFO"] = releaseFIFO.path

        let harness = fixture.root.appendingPathComponent("ordered.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const hooks = await plugin({ directory: process.cwd() });
        const orderedInfo = { id: "session-ordered", directory: process.cwd() };
        const otherInfo = { id: "session-other", directory: process.cwd() };
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const waitForLineCount = (count) => new Promise((resolve, reject) => {
          const ready = () => captureLines().length >= count;
          if (ready()) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!ready()) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error(`hook capture did not reach ${count} lines`));
          }, 2000);
        });
        const records = () => captureLines().map((line) => {
          const separator = line.indexOf("|");
          const payload = JSON.parse(line.slice(separator + 1));
          return { subcommand: line.slice(0, separator), sessionId: payload.session_id };
        });
        const releaseOrderedHook = () => fs.writeFileSync(
          process.env.TEST_HOOK_RELEASE_FIFO,
          "release\\n"
        );

        await hooks.event({ event: { type: "session.created", properties: { info: orderedInfo } } });
        await waitForLineCount(1);

        await hooks.event({ event: { type: "session.idle", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.idle", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.deleted", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.created", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.created", properties: { info: otherInfo } } });
        await waitForLineCount(2);

        const beforeRelease = records();
        releaseOrderedHook();
        await waitForLineCount(3);
        releaseOrderedHook();
        await waitForLineCount(4);
        releaseOrderedHook();
        await waitForLineCount(5);
        const afterRelease = records();
        releaseOrderedHook();
        console.log(JSON.stringify({ beforeRelease, afterRelease }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 4
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let beforeRelease = try XCTUnwrap(snapshot["beforeRelease"] as? [[String: String]])
        XCTAssertEqual(beforeRelease.compactMap { $0["sessionId"] }.sorted(), ["session-ordered", "session-other"])
        XCTAssertEqual(beforeRelease.compactMap { $0["subcommand"] }, ["session-start", "session-start"])

        let afterRelease = try XCTUnwrap(snapshot["afterRelease"] as? [[String: String]])
        let orderedCommands = afterRelease
            .filter { $0["sessionId"] == "session-ordered" }
            .compactMap { $0["subcommand"] }
        XCTAssertEqual(orderedCommands, ["session-start", "stop", "session-end", "session-start"])
    }

    func testOpenCodeQueueOverloadPreservesEveryAcceptedStartEndPair() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "if [ \"$3\" = \"session-start\" ]; then /usr/bin/nc -U \"$TEST_HOOK_RELEASE_SOCKET\" >/dev/null; fi",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseSocket = fixture.root.appendingPathComponent("release.sock", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_SOCKET"] = releaseSocket.path

        let harness = fixture.root.appendingPathComponent("overload.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import net from "node:net";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const hooks = await plugin({ directory: process.cwd() });
        let releaseStarts = false;
        const heldStarts = [];
        const releaseServer = net.createServer((socket) => {
          socket.on("error", () => {});
          if (releaseStarts) {
            socket.end("release\\n");
          } else {
            heldStarts.push(socket);
          }
        });
        await new Promise((resolve, reject) => {
          releaseServer.once("error", reject);
          releaseServer.listen(process.env.TEST_HOOK_RELEASE_SOCKET, resolve);
        });
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const records = () => captureLines().map((line) => {
          const separator = line.indexOf("|");
          const payload = JSON.parse(line.slice(separator + 1));
          return { subcommand: line.slice(0, separator), sessionId: payload.session_id };
        });
        const waitFor = (description, predicate) => new Promise((resolve, reject) => {
          if (predicate()) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!predicate()) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error(`timed out waiting for ${description}`));
          }, 6000);
        });

        const sessionIds = [
          "session-terminal-reservation",
          ...Array.from({ length: 300 }, (_, index) => `session-overload-${index}`),
        ];
        for (const sessionId of sessionIds) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.created", properties: { info } } });
        }
        for (const sessionId of sessionIds.slice(1)) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.deleted", properties: { info } } });
        }
        const terminalInfo = { id: sessionIds[0], directory: process.cwd() };
        await hooks.event({ event: { type: "session.deleted", properties: { info: terminalInfo } } });

        await waitFor("four blocked session starts", () => records().length >= 4);
        releaseStarts = true;
        for (const socket of heldStarts.splice(0)) socket.end("release\\n");
        await waitFor(
          "the terminal hook reserved while the queue was full",
          () => records().some((record) =>
            record.sessionId === "session-terminal-reservation"
              && record.subcommand === "session-end"
          )
        );
        await new Promise((resolve) => releaseServer.close(resolve));
        console.log(JSON.stringify(records()));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: String]]
        )
        let starts = records.filter { $0["subcommand"] == "session-start" }
        let ends = records.filter { $0["subcommand"] == "session-end" }
        XCTAssertGreaterThan(starts.count, 100, "fixture did not saturate the 256-slot queue")
        XCTAssertLessThan(starts.count, 301, "the bounded queue admitted every overload session")
        XCTAssertEqual(Set(starts.compactMap { $0["sessionId"] }), Set(ends.compactMap { $0["sessionId"] }))
        XCTAssertEqual(starts.count, ends.count)
        XCTAssertTrue(ends.contains { $0["sessionId"] == "session-terminal-reservation" })
    }

    func testOpenCodeRestartTerminalEventsSurviveSaturatedQueue() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "if [ \"$3\" = \"session-start\" ]; then /usr/bin/nc -U \"$TEST_HOOK_RELEASE_SOCKET\" >/dev/null; fi",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseSocket = fixture.root.appendingPathComponent("release.sock", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_SOCKET"] = releaseSocket.path

        let harness = fixture.root.appendingPathComponent("restart-terminal-overload.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import net from "node:net";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        let releaseStarts = false;
        const heldStarts = [];
        const releaseServer = net.createServer((socket) => {
          socket.on("error", () => {});
          if (releaseStarts) socket.end("release\\n");
          else heldStarts.push(socket);
        });
        await new Promise((resolve, reject) => {
          releaseServer.once("error", reject);
          releaseServer.listen(process.env.TEST_HOOK_RELEASE_SOCKET, resolve);
        });
        const hooks = await plugin({ directory: process.cwd() });
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const records = () => captureLines().map((line) => {
          const separator = line.indexOf("|");
          const payload = JSON.parse(line.slice(separator + 1));
          return { subcommand: line.slice(0, separator), sessionId: payload.session_id };
        });
        const waitFor = (description, predicate) => new Promise((resolve, reject) => {
          if (predicate()) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!predicate()) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error(`timed out waiting for ${description}`));
          }, 6000);
        });

        const saturatedIds = Array.from(
          { length: 301 },
          (_, index) => `session-saturated-${index}`
        );
        for (const sessionId of saturatedIds) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.created", properties: { info } } });
        }
        for (const sessionId of saturatedIds) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.deleted", properties: { info } } });
        }

        const deletedInfo = { id: "session-restart-deleted", directory: process.cwd() };
        await hooks.event({ event: { type: "session.deleted", properties: { info: deletedInfo } } });
        const archivedInfo = {
          id: "session-restart-archived",
          directory: process.cwd(),
          time: { archived: Date.now() },
        };
        await hooks.event({ event: { type: "session.updated", properties: { info: archivedInfo } } });

        await waitFor("four blocked starts", () => records().length >= 4);
        releaseStarts = true;
        for (const socket of heldStarts.splice(0)) socket.end("release\\n");
        await waitFor("both restart terminal events", () => {
          const ended = new Set(
            records()
              .filter((record) => record.subcommand === "session-end")
              .map((record) => record.sessionId)
          );
          return ended.has("session-restart-deleted")
            && ended.has("session-restart-archived");
        });
        await new Promise((resolve) => releaseServer.close(resolve));
        console.log(JSON.stringify(records()));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: String]]
        )
        for sessionID in ["session-restart-deleted", "session-restart-archived"] {
            let commands = records
                .filter { $0["sessionId"] == sessionID }
                .compactMap { $0["subcommand"] }
            XCTAssertEqual(commands, ["session-end"], "restart terminal event was lost for \(sessionID)")
        }
    }

    func testOpenCodeDisposeWaitsForQueuedLifecycleHooks() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "if [ \"$3\" = \"session-start\" ]; then /usr/bin/nc -U \"$TEST_HOOK_RELEASE_SOCKET\" >/dev/null; fi",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseSocket = fixture.root.appendingPathComponent("release.sock", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_SOCKET"] = releaseSocket.path

        let harness = fixture.root.appendingPathComponent("dispose-drain.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import net from "node:net";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const heldStarts = [];
        const releaseServer = net.createServer((socket) => {
          socket.on("error", () => {});
          heldStarts.push(socket);
        });
        await new Promise((resolve, reject) => {
          releaseServer.once("error", reject);
          releaseServer.listen(process.env.TEST_HOOK_RELEASE_SOCKET, resolve);
        });
        const hooks = await plugin({ directory: process.cwd() });
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const waitForLineCount = (count) => new Promise((resolve, reject) => {
          if (captureLines().length >= count) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (captureLines().length < count) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error(`hook capture did not reach ${count} lines`));
          }, 2000);
        });

        const info = { id: "session-dispose", directory: process.cwd() };
        await hooks.event({ event: { type: "session.created", properties: { info } } });
        await hooks.event({ event: { type: "session.deleted", properties: { info } } });
        await waitForLineCount(1);
        let disposed = false;
        const disposal = hooks.dispose().then(() => { disposed = true; });
        await Promise.resolve();
        const resolvedBeforeRelease = disposed;
        for (const socket of heldStarts.splice(0)) socket.end("release\\n");
        await disposal;
        await new Promise((resolve) => releaseServer.close(resolve));
        console.log(JSON.stringify({ resolvedBeforeRelease, commands: captureLines().map((line) => line.split("|", 1)[0]) }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 4
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(output["resolvedBeforeRelease"] as? Bool, false)
        XCTAssertEqual(output["commands"] as? [String], ["session-start", "session-end"])
    }

    func testOpenCodeDisposeCompactsSameSessionBacklogToFinalOutcome() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "if [ \"$3\" = \"session-start\" ]; then sleep 1; fi",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        let harness = fixture.root.appendingPathComponent("dispose-compact.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const hooks = await plugin({ directory: process.cwd() });
        const info = { id: "session-dispose-compact", directory: process.cwd() };
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const waitForFirstHook = new Promise((resolve, reject) => {
          if (captureLines().length > 0) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (captureLines().length === 0) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error("first hook did not start"));
          }, 2000);
        });

        await hooks.event({ event: { type: "session.created", properties: { info } } });
        await waitForFirstHook;
        for (let index = 0; index < 128; index += 1) {
          await hooks.event({ event: { type: "session.deleted", properties: { info } } });
          await hooks.event({ event: { type: "session.created", properties: { info } } });
        }
        await hooks.event({ event: { type: "session.deleted", properties: { info } } });

        await hooks.dispose();
        const commands = captureLines().map((line) => line.split("|", 1)[0]);
        console.log(JSON.stringify({ commands }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 4
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(output["commands"] as? [String], ["session-start", "session-end"])
    }

    func testOpenCodeDisposeAllowsPluginToReloadInSameProcess() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        let harness = fixture.root.appendingPathComponent("dispose-reload.mjs", isDirectory: false)
        try """
        import firstPlugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const firstHooks = await firstPlugin({ directory: process.cwd() });
        const firstInfo = { id: "session-before-reload", directory: process.cwd() };
        await firstHooks.event({ event: { type: "session.created", properties: { info: firstInfo } } });
        await firstHooks.dispose();

        const secondModule = await import(\(javaScriptString(fixture.pluginURL.absoluteString + "?reload=1")));
        const secondHooks = await secondModule.default({ directory: process.cwd() });
        if (typeof secondHooks.event !== "function") {
          throw new Error("reloaded OpenCode plugin did not install its event hook");
        }
        const secondInfo = { id: "session-after-reload", directory: process.cwd() };
        await secondHooks.event({ event: { type: "session.created", properties: { info: secondInfo } } });
        await secondHooks.dispose();
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let sessionIDs = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let separator = line.firstIndex(of: "|") else { return nil }
                let payload = line[line.index(after: separator)...]
                guard let object = try? JSONSerialization.jsonObject(
                    with: Data(String(payload).utf8)
                ) as? [String: Any] else {
                    return nil
                }
                return object["session_id"] as? String
            }
        XCTAssertEqual(sessionIDs, ["session-before-reload", "session-after-reload"])
    }

    func testOpenCodeDisposedFactoryCanBeReusedFromSameModule() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "case \"$payload\" in *session-after-reuse*) /usr/bin/nc -U \"$TEST_HOOK_RELEASE_SOCKET\" >/dev/null ;; esac",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseSocket = fixture.root.appendingPathComponent("release.sock", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_SOCKET"] = releaseSocket.path
        let harness = fixture.root.appendingPathComponent("dispose-reuse.mjs", isDirectory: false)
        try """
        import net from "node:net";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        let releaseHook;
        const hookConnected = new Promise((resolve) => { releaseHook = resolve; });
        const releaseServer = net.createServer((socket) => releaseHook(socket));
        await new Promise((resolve, reject) => {
          releaseServer.once("error", reject);
          releaseServer.listen(process.env.TEST_HOOK_RELEASE_SOCKET, resolve);
        });
        const firstHooks = await plugin({ directory: process.cwd() });
        const firstInfo = { id: "session-before-reuse", directory: process.cwd() };
        await firstHooks.event({ event: { type: "session.created", properties: { info: firstInfo } } });
        const firstDisposal = firstHooks.dispose();
        await Promise.resolve();
        const lateInfo = { id: "session-after-dispose", directory: process.cwd() };
        await firstHooks.event({ event: { type: "session.created", properties: { info: lateInfo } } });
        await firstDisposal;

        const secondHooks = await plugin({ directory: process.cwd() });
        const secondInfo = { id: "session-after-reuse", directory: process.cwd() };
        await secondHooks.event({ event: { type: "session.created", properties: { info: secondInfo } } });
        let secondDisposed = false;
        const secondDisposal = secondHooks.dispose().then(() => { secondDisposed = true; });
        const heldHook = await hookConnected;
        await firstHooks.dispose();
        const replacementPendingAfterStaleDispose = !secondDisposed;
        heldHook.end("release\\n");
        await secondDisposal;
        await new Promise((resolve) => releaseServer.close(resolve));
        console.log(JSON.stringify({ replacementPendingAfterStaleDispose }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Bool]
        )
        XCTAssertEqual(output["replacementPendingAfterStaleDispose"], true)
        let sessionIDs = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { hookSessionID($0) }
        XCTAssertEqual(sessionIDs, ["session-before-reuse", "session-after-reuse"])
    }

    func testOpenCodeShutdownPreservesDistinctSessionStopsAtQueueSaturation() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "if [ \"$3\" = \"session-start\" ]; then sleep 1; fi",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        let harness = fixture.root.appendingPathComponent("dispose-distinct-stops.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const hooks = await plugin({ directory: process.cwd() });
        const sessionIds = Array.from({ length: 130 }, (_, index) => `session-stop-${index}`);
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const waitForFourStarts = new Promise((resolve, reject) => {
          if (captureLines().length >= 4) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (captureLines().length < 4) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error("four starts did not dispatch"));
          }, 2000);
        });
        for (const sessionId of sessionIds) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.created", properties: { info } } });
        }
        await waitForFourStarts;
        for (const sessionId of sessionIds) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.idle", properties: { info } } });
        }
        await hooks.dispose();
        console.log(captureLines().join("\\n"));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        var commandsBySession: [String: [String]] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "|"),
                  let sessionID = hookSessionID(line)
            else { continue }
            commandsBySession[sessionID, default: []].append(String(line[..<separator]))
        }
        XCTAssertEqual(commandsBySession.count, 130)
        for index in 0..<130 {
            let sessionID = "session-stop-\(index)"
            XCTAssertEqual(commandsBySession[sessionID]?.last, "stop", "lost final stop for \(sessionID)")
        }
    }

    func testOpenCodeStopWithoutPriorStartCreatesRestorableDurableRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-stop-only-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/yes", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let stateURL = stateDirectory.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        let registryURL = stateDirectory.appendingPathComponent(
            CmuxAgentSessionRegistry.filename,
            isDirectory: false
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let environment = [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "opencode-stop-only-runtime",
        ]
        let launchCommand = AgentHookLaunchCommandRecord(
            launcher: "opencode",
            executablePath: executable.path,
            arguments: [executable.path],
            workingDirectory: root.path,
            environment: nil,
            capturedAt: Date().timeIntervalSince1970,
            source: "process"
        )
        let store = ClaudeHookSessionStore(processEnv: environment, agentName: "opencode")
        let stop = try store.recordPromptStop(
            sessionId: "session-stop-only",
            workspaceId: workspaceID.uuidString,
            surfaceId: surfaceID.uuidString,
            cwd: root.path,
            pid: Int(process.processIdentifier),
            launchCommand: launchCommand,
            agentLifecycle: .idle,
            lastSubtitle: "Completed",
            lastBody: "OpenCode session completed",
            runtimeStatus: .idle,
            updateRuntimeStatus: true
        )

        XCTAssertTrue(stop.accepted)
        let record = try XCTUnwrap(try store.lookup(sessionId: "session-stop-only"))
        XCTAssertEqual(record.sessionState, .active)
        XCTAssertEqual(record.restoreAuthority, true)
        XCTAssertEqual(record.agentLifecycle, .idle)
        XCTAssertEqual(record.runtimeStatus, .idle)
        XCTAssertEqual(record.launchCommand?.arguments, [executable.path])
        let restored = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: .default
        ).exactEntry(workspaceId: workspaceID, panelId: surfaceID)?.snapshot
        XCTAssertEqual(restored?.kind, .opencode)
        XCTAssertEqual(restored?.sessionId, "session-stop-only")
        XCTAssertNotNil(restored?.resumeCommand)
    }

    func testOpenCodeNaturalExitDrainsQueuedLifecycleHooks() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "if [ \"$3\" = \"session-start\" ]; then sleep 0.35; fi",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        let harness = fixture.root.appendingPathComponent("natural-exit-drain.mjs", isDirectory: false)
        try """
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));
        const hooks = await plugin({ directory: process.cwd() });
        const info = { id: "session-natural-exit", directory: process.cwd() };
        await hooks.event({ event: { type: "session.created", properties: { info } } });
        await hooks.event({ event: { type: "session.deleted", properties: { info } } });
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 3
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let commands = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) }
        XCTAssertEqual(commands, ["session-start", "session-end"])
    }

    func testOpenCodeInstallHooksIsIdempotentForLegacySetupAlias() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-opencode-hooks-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let configURL = configDir.appendingPathComponent("opencode.json", isDirectory: false)
        try #"{"plugin":["other-plugin","./plugins/cmux-session.js"]}"#.write(to: configURL, atomically: true, encoding: .utf8)
        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_CONFIG_DIR"] = configDir.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(executablePath: cliPath, arguments: ["hooks", "opencode", "install", "--yes"], environment: environment, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let pluginURL = configDir.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent("cmux-session.js", isDirectory: false)
        let pluginSource = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(pluginSource.contains("cmux-opencode-session-plugin-marker"))
        XCTAssertTrue(pluginSource.contains("\"hooks\", \"opencode\""))

        let secondResult = runProcess(executablePath: cliPath, arguments: ["setup-hooks", "--agent", "opencode"], environment: environment, timeout: 5)
        XCTAssertFalse(secondResult.timedOut, secondResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
        XCTAssertFalse(secondResult.stdout.contains("Will write OpenCode cmux plugin"), secondResult.stdout)
        XCTAssertTrue(secondResult.stdout.contains("OpenCode hooks already up to date"), secondResult.stdout)
        XCTAssertTrue(try String(contentsOf: configDir.appendingPathComponent("plugins/cmux-feed.js"), encoding: .utf8).contains("cmux-feed-plugin-marker"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: configURL), options: []) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(json["plugin"] as? [String]), ["other-plugin", "./plugins/cmux-session.js"])
    }

    func testLegacyHookAliasesAreHiddenFromHelp() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(executablePath: cliPath, arguments: ["help"], environment: environment, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stdout.contains("codex <install-hooks|uninstall-hooks>"), result.stdout)
        XCTAssertFalse(result.stdout.contains("claude-hook <session-start|stop|notification>"), result.stdout)
        XCTAssertFalse(result.stdout.contains("codex-hook"), result.stdout)
        XCTAssertFalse(result.stdout.contains("feed-hook"), result.stdout)
        XCTAssertFalse(result.stdout.contains("setup-hooks"), result.stdout)
        XCTAssertFalse(result.stdout.contains("uninstall-hooks"), result.stdout)
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private struct OpenCodePluginFixture {
        let root: URL
        let pluginURL: URL
        let environment: [String: String]
    }

    private func makeOpenCodePluginFixture(fakeCmuxLines: [String]) throws -> OpenCodePluginFixture {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-plugin-runtime-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try #"{"type":"module"}"#.write(
            to: configDir.appendingPathComponent("package.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)
        let fakeCmuxURL = binDir.appendingPathComponent("cmux-hook", isDirectory: false)
        try (["#!/bin/sh"] + fakeCmuxLines + ["exit 0"]).joined(separator: "\n")
            .appending("\n")
            .write(to: fakeCmuxURL, atomically: true, encoding: .utf8)
        chmod(fakeCmuxURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_CONFIG_DIR"] = configDir.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let install = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "opencode", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        guard !install.timedOut, install.status == 0 else {
            XCTFail("OpenCode hook install failed: \(install.stderr)")
            throw NSError(domain: "OpenCodeHookRegressionTests", code: Int(install.status))
        }
        environment["CMUX_SURFACE_ID"] = "surface-opencode-runtime"
        environment["CMUX_OPENCODE_CMUX_BIN"] = fakeCmuxURL.path
        return OpenCodePluginFixture(
            root: root,
            pluginURL: configDir.appendingPathComponent("plugins/cmux-session.js", isDirectory: false),
            environment: environment
        )
    }

    private func javaScriptString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [])
        let array = try XCTUnwrap(String(data: data, encoding: .utf8))
        return String(array.dropFirst().dropLast())
    }

    private func hookSessionID<S: StringProtocol>(_ line: S) -> String? {
        guard let separator = line.firstIndex(of: "|") else { return nil }
        let payload = line[line.index(after: separator)...]
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(String(payload).utf8)
        ) as? [String: Any] else {
            return nil
        }
        return object["session_id"] as? String
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
