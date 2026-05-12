import XCTest
import Darwin

final class OpenCodeHookRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    func testOpenCodeFeedPluginEmitsCompletionNotificationOnSessionIdle() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repoRoot.appendingPathComponent("Resources/opencode-plugin.js", isDirectory: false)
        XCTAssertTrue(fileManager.fileExists(atPath: pluginURL.path), "Missing bundled OpenCode plugin at \(pluginURL.path)")

        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-opencode-feed-\(UUID().uuidString)", isDirectory: true)
        let worktree = root.appendingPathComponent("opencode-completion-project", isDirectory: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let socketPath = "/tmp/cmux-opencode-feed-\(UUID().uuidString).sock"
        defer { unlink(socketPath) }

        let harnessURL = root.appendingPathComponent("opencode-feed-notification-harness.js", isDirectory: false)
        try Self.openCodeFeedNotificationHarness.write(to: harnessURL, atomically: true, encoding: .utf8)

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "node",
                harnessURL.path,
                pluginURL.path,
                socketPath,
                workspaceID,
                surfaceID,
                worktree.path,
            ],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let data = try XCTUnwrap(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let frames = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]])
        let methods = frames.compactMap { $0["method"] as? String }
        XCTAssertEqual(
            methods.filter { $0 == "notification.create_for_caller" }.count,
            2,
            "Expected session.idle and session.status:idle to create notification frames; saw methods \(methods)"
        )
        let notificationFrame = try XCTUnwrap(frames.first { $0["method"] as? String == "notification.create_for_caller" })
        let params = try XCTUnwrap(notificationFrame["params"] as? [String: Any])
        XCTAssertEqual(params["title"] as? String, "OpenCode")
        XCTAssertEqual(params["subtitle"] as? String, "Completed in opencode-completion-project")
        XCTAssertEqual(params["body"] as? String, "OpenCode session completed")
        XCTAssertEqual(params["preferred_workspace_id"] as? String, workspaceID)
        XCTAssertEqual(params["preferred_surface_id"] as? String, surfaceID)
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
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux", item.path.contains(".app/Contents/Resources/bin/cmux") else { continue }
            return item.path
        }
        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private static let openCodeFeedNotificationHarness = #"""
const nodeNet = require("node:net");
const nodeFs = require("node:fs");

(async () => {
  const [pluginPath, socketPath, workspaceId, surfaceId, worktree] = process.argv.slice(2);
  try {
    nodeFs.unlinkSync(socketPath);
  } catch (_) {}

  const frames = [];
  const waiters = [];
  const noteFrame = (frame) => {
    frames.push(frame);
    for (let index = waiters.length - 1; index >= 0; index -= 1) {
      const waiter = waiters[index];
      if (!waiter.predicate(frame)) continue;
      waiters.splice(index, 1);
      clearTimeout(waiter.timeout);
      waiter.resolve(frame);
    }
  };
  const waitForFrame = (predicate, label) => {
    const existing = frames.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const index = waiters.findIndex((waiter) => waiter.resolve === resolve);
        if (index >= 0) waiters.splice(index, 1);
        reject(new Error(`Timed out waiting for ${label}; saw ${JSON.stringify(frames)}`));
      }, 2000);
      waiters.push({ predicate, resolve, timeout });
    });
  };
  const notificationCount = () =>
    frames.filter((frame) => frame.method === "notification.create_for_caller").length;
  const sockets = new Set();
  const server = nodeNet.createServer((conn) => {
    sockets.add(conn);
    conn.setEncoding("utf8");
    let buffered = "";
    conn.on("data", (chunk) => {
      buffered += chunk;
      let idx;
      while ((idx = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, idx);
        buffered = buffered.slice(idx + 1);
        if (!line.trim()) continue;
        const frame = JSON.parse(line);
        noteFrame(frame);
        conn.write(JSON.stringify({
          id: frame.id,
          ok: true,
          result: { status: "acknowledged" },
        }) + "\n");
      }
    });
    conn.on("close", () => {
      sockets.delete(conn);
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.off("error", reject);
      resolve();
    });
  });

  process.env.CMUX_SOCKET_PATH = socketPath;
  process.env.CMUX_WORKSPACE_ID = workspaceId;
  process.env.CMUX_SURFACE_ID = surfaceId;

  const source = nodeFs.readFileSync(pluginPath, "utf8")
    .replace("export const CMUXFeed = async", "globalThis.CMUXFeed = async");
  eval(source);

  const hooks = await globalThis.CMUXFeed({ directory: worktree, worktree });
  await hooks.event({
    event: {
      type: "session.created",
      properties: { info: { id: "ses-opencode-complete", directory: worktree } },
    },
  });
  await hooks.event({
    event: {
      type: "session.idle",
      properties: { sessionID: "ses-opencode-complete" },
    },
  });
  await waitForFrame(
    (frame) => frame.method === "notification.create_for_caller",
    "session.idle notification"
  );

  await hooks.event({
    event: {
      type: "session.created",
      properties: { info: { id: "ses-opencode-status-complete", directory: worktree } },
    },
  });
  await hooks.event({
    event: {
      type: "session.status",
      sessionID: "ses-opencode-status-complete",
      properties: { status: { type: "idle" } },
    },
  });
  await waitForFrame(
    () => notificationCount() >= 2,
    "session.status idle notification with top-level sessionID"
  );

  for (const socket of sockets) socket.destroy();
  await new Promise((resolve) => server.close(resolve));
  try {
    nodeFs.unlinkSync(socketPath);
  } catch (_) {}
  console.log(JSON.stringify(frames));
})().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
"""#

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
