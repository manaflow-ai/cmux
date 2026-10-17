import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
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
 * still faulting its snapshot's blocks in from the host.
 */
function fakeCmuxTui(directory: string, blankSnapshots: number): string {
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

function runSmoke(blankSnapshots: number) {
  const directory = mkdtempSync(path.join(tmpdir(), "cmux-ws-smoke-"));
  try {
    const script = path.join(directory, "smoke.sh");
    writeFileSync(script, smokeScript());
    const result = spawnSync("bash", [script], {
      env: { PATH: process.env.PATH, HOME: directory, CMUX_TUI_BIN: fakeCmuxTui(directory, blankSnapshots) },
      encoding: "utf8",
      timeout: 60_000,
    });
    return { code: result.status, out: `${result.stdout}${result.stderr}` };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("the websocket smoke waits for a login shell that is slow to print", () => {
  const result = runSmoke(4);
  expect(result.out).toContain("websocket-smoke-ok");
  expect(result.code).toBe(0);
}, 60_000);

test("the websocket smoke still fails when the pane never shows the marker", () => {
  const result = runSmoke(1_000);
  expect(result.code).not.toBe(0);
  expect(result.out).not.toContain("websocket-smoke-ok");
}, 90_000);
