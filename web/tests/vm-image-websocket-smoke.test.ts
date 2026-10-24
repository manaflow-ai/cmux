import { expect, test } from "bun:test";
import { execFile } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { cmuxTuiWebsocketSmokeCommand } from "../scripts/devbox-image-common";
import { DEVBOX_HOSTNAME } from "../services/vms/images/identity";
import { DEVBOX_WORK_USER } from "../services/vms/images/workUser";

/** The bash probe the command decodes onto the guest. */
function smokeScript(): string {
  const encoded = /printf %s (\S+) \| base64 -d/.exec(cmuxTuiWebsocketSmokeCommand())?.[1];
  if (!encoded) throw new Error("smoke command no longer embeds its script");
  return Buffer.from(encoded, "base64").toString("utf8");
}

/**
 * A cmux-tui stand-in whose spawned pane stays blank for the first
 * `blankSnapshots` terminal snapshots, the way a login shell is on a machine
 * still faulting its snapshot's blocks in from the host. With `hangSnapshots`
 * every snapshot request hangs, like a connection that never answers.
 */
function fakeCmuxTui(directory: string, blankSnapshots: number, hangSnapshots = false): string {
  const binary = path.join(directory, "cmux-tui");
  writeFileSync(binary, `#!/usr/bin/env bash
set -euo pipefail
STATE=${JSON.stringify(directory)}
case "$1 $2" in
  "remote enroll")
    case "$3" in
      create) echo '{"invitation":"cmux://enroll/fake"}' ;;
      pending) echo '[{"invitation_id":"inv","device_fingerprint":"dev"}]' ;;
      *) echo '{}' ;;
    esac ;;
  "remote connect") exec sleep 30 ;;
  "remote rpc")
    while [ "$1" != --request ]; do shift; done
    request="$2"
    case "$(jq -r .type <<<"$request")" in
      capabilities) echo '{"type":"capabilities","capabilities":[]}' ;;
      open-workspace) echo '{"type":"workspace","id":"ws"}' ;;
      spawn-process)
        jq -r '.argv[2]' <<<"$request" | grep -o 'CMUX_WS_SMOKE_[A-Za-z0-9_]*' >"$STATE/marker"
        echo '{"type":"process-started","process":"proc"}' ;;
      snapshot-process-terminal)
        ${hangSnapshots ? "exec sleep 600" : ":"}
        count=$(( $(cat "$STATE/snapshots" 2>/dev/null || echo 0) + 1 ))
        echo "$count" >"$STATE/snapshots"
        text=""
        if [ "$count" -gt ${blankSnapshots} ]; then text="$(cat "$STATE/marker"):${DEVBOX_WORK_USER}@${DEVBOX_HOSTNAME}"; fi
        jq -nc --arg text "$text" --argjson sequence "$count" \\
          '{type:"process-terminal-snapshot",snapshot:{rows:[{row:0,runs:[{text:$text}]}],through_sequence:$sequence}}' ;;
      *) echo '{}' ;;
    esac ;;
  *) echo "unexpected cmux-tui $*" >&2; exit 2 ;;
esac
`);
  chmodSync(binary, 0o755);
  return binary;
}

/** GNU timeout ships on the guest; a host without it (macOS) gets a pass-through. */
async function ensureTimeout(directory: string): Promise<string> {
  try {
    await promisify(execFile)("timeout", ["1", "true"]);
    return process.env.PATH ?? "";
  } catch {
    const bin = path.join(directory, "bin");
    mkdirSync(bin);
    writeFileSync(path.join(bin, "timeout"), `#!/usr/bin/env bash
while [ "\${1#--}" != "$1" ]; do shift; done
limit="$1"; shift
"$@" & child=$!
( sleep "$limit"; kill -TERM "$child" ) >/dev/null 2>&1 & watcher=$!
wait "$child"; code=$?
kill "$watcher" 2>/dev/null
exit "$code"
`);
    chmodSync(path.join(bin, "timeout"), 0o755);
    return `${bin}:${process.env.PATH ?? ""}`;
  }
}

async function runSmoke(blankSnapshots: number, hangSnapshots = false) {
  const directory = mkdtempSync(path.join(tmpdir(), "cmux-ws-smoke-"));
  try {
    const script = path.join(directory, "smoke.sh");
    writeFileSync(script, smokeScript());
    const env = { ...process.env, PATH: await ensureTimeout(directory), HOME: directory, CMUX_TUI_BIN: fakeCmuxTui(directory, blankSnapshots, hangSnapshots) };
    try {
      const { stdout, stderr } = await promisify(execFile)("bash", [script], { env, encoding: "utf8", timeout: 80_000 });
      return { code: 0, out: `${stdout}${stderr}` };
    } catch (error) {
      const failed = error as { code?: number; stdout?: string; stderr?: string };
      return { code: failed.code ?? 1, out: `${failed.stdout ?? ""}${failed.stderr ?? ""}` };
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("the websocket smoke waits for a login shell that is slow to print", async () => {
  const result = await runSmoke(4);
  expect(result.out).toContain("websocket-smoke-ok");
  expect(result.code).toBe(0);
}, 60_000);

test("the websocket smoke still fails when the pane never shows the marker", async () => {
  const result = await runSmoke(1_000);
  expect(result.code).not.toBe(0);
  expect(result.out).not.toContain("websocket-smoke-ok");
}, 90_000);

test("a snapshot request that never answers cannot outlive the poll's deadline", async () => {
  const started = Date.now();
  const result = await runSmoke(0, true);
  expect(result.code).not.toBe(0);
  expect(result.out).not.toContain("websocket-smoke-ok");
  // 30s poll budget plus the kill grace, well under the callers' 120s exec timeout.
  expect(Date.now() - started).toBeLessThan(45_000);
}, 90_000);
