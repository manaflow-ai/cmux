#!/usr/bin/env python3
"""The server-context OpenCode session plugin tags child sessions as subagents.

A child session shares its parent's surface, so cmux cannot tell it apart by
process ancestry. The plugin must set CMUX_AGENT_MANAGED_SUBAGENT=1 on hooks
for a session whose info carries a parent ID, whether that ID first arrives in
session.created or session.updated, and must leave root sessions untagged.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def session_plugin_source() -> str:
    swift = (ROOT / "CLI/cmux.swift").read_text(encoding="utf-8")
    match = re.search(r'openCodeSessionPluginSource = #"""\n(.*?)\n"""#', swift, re.S)
    if match is None:
        raise RuntimeError("openCodeSessionPluginSource not found")
    return match.group(1)


HARNESS = r'''
const { pluginPath, logPath, fakeCmux } = JSON.parse(process.env.CMUX_OPENCODE_SUBAGENT_HARNESS);
const fs = await import("node:fs");
const { execFileSync } = await import("node:child_process");

const mod = await import(pluginPath);
const ctx = {
  client: {},
  project: { id: "project" },
  worktree: "/tmp",
  directory: "/tmp",
  serverUrl: new URL("http://127.0.0.1:4096"),
  $: () => {},
};
const hooks = await mod.default.server(ctx, {});
const emit = (event) => hooks.event({ event });

const turn = async (sid, opening) => {
  await emit(opening);
  await emit({ type: "session.status", properties: { sessionID: sid, status: { type: "busy" } } });
  await emit({ type: "session.idle", properties: { sessionID: sid } });
};

await turn("root", { type: "session.created", properties: { info: { id: "root", directory: "/tmp" } } });
await turn("child-created", { type: "session.created", properties: { info: { id: "child-created", parentID: "root", directory: "/tmp" } } });
// The live event stream does not replay session.created, so a child can first
// appear through session.updated.
await turn("child-updated", { type: "session.updated", properties: { info: { id: "child-updated", parentID: "root", directory: "/tmp" } } });

const running = () => {
  try {
    execFileSync("pgrep", ["-f", fakeCmux], { stdio: "ignore" });
    return true;
  } catch (_) {
    return false;
  }
};
const deadline = Date.now() + 20000;
const stops = () => (fs.existsSync(logPath) ? fs.readFileSync(logPath, "utf8") : "")
  .split("\n").filter((line) => line.includes("hooks enqueue opencode stop"));
while (stops().length < 3 || running()) {
  if (Date.now() > deadline) throw new Error(`hooks did not finish: ${stops().join("\n")}`);
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const stopFor = (sid) => stops().find((line) => line.includes(`"session_id":"${sid}"`));
const tag = (sid) => {
  const line = stopFor(sid);
  if (!line) throw new Error(`no stop hook for ${sid}: ${stops().join("\n")}`);
  return line.split(" ")[0];
};
if (tag("root") !== "subagent=") throw new Error(`root session was tagged: ${stopFor("root")}`);
if (tag("child-created") !== "subagent=1") throw new Error(`child from session.created untagged: ${stopFor("child-created")}`);
if (tag("child-updated") !== "subagent=1") throw new Error(`child from session.updated untagged: ${stopFor("child-updated")}`);
console.log("PASS: OpenCode session plugin tags child sessions as subagents");
process.exit(0);
'''


def main() -> int:
    node = shutil.which("node")
    if node is None:
        print("SKIP: node not found")
        return 0
    with tempfile.TemporaryDirectory(prefix="cmux-opencode-subagent-") as td:
        root = Path(td)
        plugin_path = root / "cmux-session.js"
        plugin_path.write_text(session_plugin_source(), encoding="utf-8")
        (root / "package.json").write_text('{"type":"module"}', encoding="utf-8")
        log_path = root / "cmux.log"
        fake_cmux = root / "cmux"
        fake_cmux.write_text(
            f'#!/bin/sh\necho "subagent=$CMUX_AGENT_MANAGED_SUBAGENT $* $(cat)" >> "{log_path}"\n',
            encoding="utf-8",
        )
        fake_cmux.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k != "CMUX_AGENT_MANAGED_SUBAGENT"}
        env.update(
            CMUX_SURFACE_ID="surface-subagent-tag",
            CMUX_WORKSPACE_ID="workspace-subagent-tag",
            CMUX_SOCKET_PATH=str(root / "cmux.sock"),
            CMUX_OPENCODE_CMUX_BIN=str(fake_cmux),
            CMUX_OPENCODE_HOOKS_DISABLED="",
            CMUX_OPENCODE_SUBAGENT_HARNESS=json.dumps(
                {"pluginPath": str(plugin_path), "logPath": str(log_path), "fakeCmux": str(fake_cmux)}
            ),
        )
        harness = root / "harness.mjs"
        harness.write_text(HARNESS, encoding="utf-8")
        result = subprocess.run([node, str(harness)], env=env, capture_output=True, text=True, timeout=30)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            print(f"FAIL: {output[-3000:]}")
            return 1
        print(output)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
