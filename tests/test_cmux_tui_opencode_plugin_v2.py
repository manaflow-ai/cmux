#!/usr/bin/env python3
"""cmux-tui's OpenCode journal plugin loads and journals on OpenCode 2 (#42158).

`cmux agent hook install opencode` writes the plugin template from
cmux-tui/crates/cmux-tui/assets/agent-hooks/opencode.js. OpenCode 2 (checked
against v2.2.7, packages/core/src/plugin/module.ts) rejects any module whose
default export is not `{ id: string, setup | effect: function }`, and its
promise-style `setup(context)` receives events through
`context.event.subscribe({ signal })` instead of a returned `event` hook.

These run the real template under Node with a fake OpenCode 2 context and a
fake cmux-tui hook helper that records what it is sent. npm's opencode-ai is
still 1.x, so one test also loads the template the way OpenCode 1.x does
(a default `{ id, server }` object, or plugin-function exports).
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "cmux-tui/crates/cmux-tui/assets/agent-hooks/opencode.js"

# Runs inside Node. Reads its inputs from CMUX_TEST_HARNESS and prints one JSON result line.
HARNESS = r"""
const { pluginPath, helperLog, events, mode } = JSON.parse(process.env.CMUX_TEST_HARNESS);
const fs = await import("node:fs");
const { pathToFileURL } = await import("node:url");
const { createRequire, syncBuiltinESMExports } = await import("node:module");

// Track every helper the plugin spawns, so the test can wait for each one to
// exit instead of sleeping. This must run before the plugin imports `spawn`.
const childProcess = createRequire(import.meta.url)("node:child_process");
const realSpawn = childProcess.spawn;
const helperExits = [];
childProcess.spawn = (...args) => {
  const child = realSpawn(...args);
  helperExits.push(new Promise((resolve) => child.on("close", resolve)));
  return child;
};
syncBuiltinESMExports();

// Fails the run instead of hanging if a completion signal never arrives.
function within(promise, what) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), 10000);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

const result = { shape: {}, subscribeOptions: null, aborted: false, cleanupType: null, calls: [] };
const mod = await import(pathToFileURL(pluginPath).href);
const plugin = mod.default;
result.shape = {
  defaultType: plugin === null ? "null" : typeof plugin,
  idType: typeof plugin?.id,
  setupType: typeof plugin?.setup,
  effectType: typeof plugin?.effect,
};

// Call once every event has been handled: by then the plugin has spawned every
// helper it will spawn, and each one has written its record before exiting.
async function collectCalls() {
  await within(Promise.all(helperExits), "the hook helpers to exit");
  const lines = fs.existsSync(helperLog) ? fs.readFileSync(helperLog, "utf8").split("\n").filter(Boolean) : [];
  return lines.map((line) => JSON.parse(line));
}

if (mode === "v1") {
  // OpenCode 1.4.0+ (checked at v1.19.5, packages/opencode/src/plugin/{index,shared}.ts):
  // a default object with `id` or `server` must provide `server(input)`;
  // otherwise every export must be a plugin function. OpenCode before 1.4.0
  // calls every export as a function, so it can't load an object default.
  const isV1Object =
    plugin && typeof plugin === "object" && ("id" in plugin || "server" in plugin || "tui" in plugin);
  const servers = isV1Object
    ? [plugin.server]
    : [...new Set(Object.values(mod))].map((entry) => (typeof entry === "function" ? entry : entry?.server));
  if (servers.some((server) => typeof server !== "function")) throw new Error("OpenCode 1.x would reject this plugin");
  const input = { client: {}, project: { id: "prj_1" }, directory: "/work/project", worktree: "/work", $: () => {} };
  const hooks = await Promise.all(servers.map((server) => server(input)));
  for (const event of events) {
    for (const hook of hooks) await hook?.event?.({ event });
  }
  result.calls = await collectCalls();
} else if (typeof plugin?.setup === "function") {
  let signal;
  let drained;
  const streamDrained = new Promise((resolve) => (drained = resolve));
  const context = {
    location: {
      directory: "/work/project",
      project: { id: "prj_1", directory: "/work", canonical: "/work" },
    },
    event: {
      subscribe(options) {
        signal = options?.signal;
        result.subscribeOptions = { hasSignal: signal instanceof AbortSignal };
        return (async function* () {
          for (const event of events) yield event;
          // The plugin asked for the next event, so it has handled every one.
          drained();
          // A live stream stays open until the subscriber aborts.
          await new Promise((resolve) => signal?.addEventListener("abort", resolve, { once: true }));
        })();
      },
    },
  };
  const cleanup = await plugin.setup(context);
  result.cleanupType = typeof cleanup;
  await within(streamDrained, "the plugin to read every event");
  result.calls = await collectCalls();

  if (typeof cleanup === "function") await cleanup();
  result.aborted = signal?.aborted === true;
}

console.log(JSON.stringify(result));
process.exit(0);
"""

# Records each invocation as one JSON line: argv plus the JSON payload read from stdin.
FAKE_HELPER = r"""#!/usr/bin/env node
const fs = require("node:fs");
let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (stdin += chunk));
process.stdin.on("end", () => {
  fs.appendFileSync(process.env.CMUX_TEST_HELPER_LOG, JSON.stringify({ argv: process.argv.slice(2), payload: JSON.parse(stdin) }) + "\n");
});
"""

SESSION_EVENTS = [
    {"type": "session.created", "data": {"sessionID": "ses_1"}, "journaled": True},
    # Streaming deltas are deliberately not journaled.
    {"type": "session.text.delta", "data": {"sessionID": "ses_1", "delta": "hi"}, "journaled": False},
    {"type": "session.execution.succeeded", "data": {"sessionID": "ses_1"}, "journaled": True},
]

# OpenCode 1.x events carry `properties` instead of `data`.
V1_SESSION_EVENTS = [
    {"type": "session.created", "properties": {"info": {"id": "ses_1"}}, "journaled": True},
    {"type": "message.part.updated", "properties": {"sessionID": "ses_1"}, "journaled": False},
    {"type": "session.idle", "properties": {"sessionID": "ses_1"}, "journaled": True},
]


class OpenCode2JournalPluginTests(unittest.TestCase):
    def run_harness(self, events: list[dict], mode: str = "v2") -> dict:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin = root / "cmux-tui-journal.mjs"
            plugin.write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
            helper = root / "cmux-tui-hook"
            helper.write_text(FAKE_HELPER, encoding="utf-8")
            helper.chmod(0o755)
            helper_log = root / "helper.log"
            harness = root / "harness.mjs"
            harness.write_text(HARNESS, encoding="utf-8")
            env = {
                **os.environ,
                "CMUX_TUI_HOOK": str(helper),
                "CMUX_TUI_SOCKET": str(root / "cmux-tui.sock"),
                "CMUX_TUI_TERMINAL_ID": "term_1",
                "CMUX_TEST_HELPER_LOG": str(helper_log),
                "CMUX_TEST_HARNESS": json.dumps(
                    {"pluginPath": str(plugin), "helperLog": str(helper_log), "events": events, "mode": mode}
                ),
            }
            result = subprocess.run(
                ["node", str(harness)], env=env, capture_output=True, text=True, timeout=30
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout.strip().splitlines()[-1])

    def test_default_export_matches_the_opencode_2_module_schema(self):
        shape = self.run_harness([])["shape"]
        self.assertEqual(shape["defaultType"], "object", "OpenCode 2 rejects a function default export")
        self.assertEqual(shape["idType"], "string")
        self.assertEqual(shape["setupType"], "function")

    def test_setup_journals_subscribed_session_events(self):
        result = self.run_harness(SESSION_EVENTS)
        self.assertEqual(result["subscribeOptions"], {"hasSignal": True})
        # Each event spawns its own helper process, so arrival order is not fixed.
        self.assertCountEqual(
            [call["argv"] for call in result["calls"]],
            [["opencode", "session.created"], ["opencode", "session.execution.succeeded"]],
        )
        for call in result["calls"]:
            context = call["payload"]["context"]
            self.assertEqual(context["directory"], "/work/project")
            self.assertEqual(context["worktree"], "/work")
            self.assertEqual(context["session_id"], "ses_1")
            self.assertEqual(context["root_session_id"], "ses_1")
            self.assertEqual(call["payload"]["event"]["data"]["sessionID"], "ses_1")

    def test_cleanup_ends_the_event_subscription(self):
        result = self.run_harness(SESSION_EVENTS)
        self.assertEqual(result["cleanupType"], "function")
        self.assertTrue(result["aborted"], "cleanup must abort the subscription so OpenCode can unload the plugin")

    def test_opencode_1_server_entry_still_journals(self):
        # npm's opencode-ai is still 1.x, which loads the same file through `server`.
        result = self.run_harness(V1_SESSION_EVENTS, mode="v1")
        self.assertCountEqual(
            [call["argv"] for call in result["calls"]],
            [["opencode", "session.created"], ["opencode", "session.idle"]],
        )
        for call in result["calls"]:
            context = call["payload"]["context"]
            self.assertEqual(context["directory"], "/work/project")
            self.assertEqual(context["worktree"], "/work")
            self.assertEqual(context["session_id"], "ses_1")


if __name__ == "__main__":
    unittest.main()
