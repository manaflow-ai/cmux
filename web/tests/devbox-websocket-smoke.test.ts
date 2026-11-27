import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { cmuxTuiWebsocketSmokeScript } from "../scripts/devbox-image-common";
import { DEVBOX_HOSTNAME } from "../services/vms/images/identity";
import { DEVBOX_WORK_USER } from "../services/vms/images/workUser";
import { runChild } from "./helpers/run-child";

/**
 * A fake cmux-tui for the WebSocket smoke. Its `remote connect` registers a
 * pending request under its --device-name, waits for that request's approval,
 * waits FAKE_PIN_DELAY more seconds, and only then records the daemon in its
 * state dir, like the real connector, which records it after its first
 * connect completes. `remote rpc` answers only when the daemon is recorded,
 * and otherwise fails with the real client's error. The pending list also
 * carries a stale request from another device, listed first.
 */
function fakeCmuxTui(dir: string): string {
  const binary = join(dir, "cmux-tui");
  writeFileSync(binary, `#!/usr/bin/env bash
set -u
F=${JSON.stringify(dir)}
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do if [ "$1" = "$want" ]; then printf '%s' "$2"; return; fi; shift; done; }
case "$1 $2 \${3:-}" in
  "remote enroll create") echo '{"uri":"cmux://enroll/fake"}' ;;
  "remote enroll pending")
    if [ -f "$F/device" ]; then
      printf '[{"invitation_id":"stale","device_name":"another-device","device_fingerprint":"fp-stale"},{"invitation_id":"ours","device_name":"%s","device_fingerprint":"fp-ours"}]\\n' "$(cat "$F/device")"
    else
      echo '[{"invitation_id":"stale","device_name":"another-device","device_fingerprint":"fp-stale"}]'
    fi ;;
  "remote enroll approve") echo "$4" >>"$F/approved"; echo '{}' ;;
  "remote enroll revoke"|"remote enroll deny") echo '{}' ;;
  "remote connect --invite-file")
    if [ -n "\${FAKE_CONNECT_FAIL:-}" ]; then echo "connector: $FAKE_CONNECT_FAIL" >&2; exit 3; fi
    STATE="$(arg --state-dir "$@")"
    arg --device-name "$@" >"$F/device"
    until grep -qx ours "$F/approved" 2>/dev/null; do sleep 0.05; done
    sleep "\${FAKE_PIN_DELAY:-0}"
    echo '[{"fingerprint":"fp-daemon","route_hints":["ws://[::1]:1337/"]}]' >"$STATE/known.json"
    echo '{"event":"connection-snapshot","connection":{"state":"connected"}}'
    exec sleep 600 ;;
  "remote known-daemons --state-dir")
    STATE="$4"
    if [ -f "$STATE/known.json" ]; then cat "$STATE/known.json"; else echo '[]'; fi ;;
  "remote rpc ws://[::1]:1337/v1/link")
    STATE="$(arg --state-dir "$@")"
    REQUEST="$(arg --request "$@")"
    if [ ! -f "$STATE/known.json" ]; then
      echo "cmux-tui: no known daemon matches this route; connect with an invitation" >&2
      exit 1
    fi
    case "$REQUEST" in
      *'"capabilities"'*) echo '{"type":"capabilities"}' ;;
      *'"open-workspace"'*) echo '{"id":"ws-1"}' ;;
      *'"spawn-process"'*) printf '%s' "$REQUEST" >"$F/spawn"; echo '{"process":"proc-1"}' ;;
      *'"snapshot-process-terminal"'*)
        MARKER="$(grep -o 'CMUX_WS_SMOKE_[A-Za-z0-9]*_[0-9]*' "$F/spawn" | head -1)"
        printf '{"snapshot":{"through_sequence":1,"text":"%s:%s"}}\\n' "$MARKER" ${JSON.stringify(`${DEVBOX_WORK_USER}@${DEVBOX_HOSTNAME}`)} ;;
      *) echo '{}' ;;
    esac ;;
  *) echo "fake cmux-tui: unexpected $*" >&2; exit 64 ;;
esac
`);
  chmodSync(binary, 0o755);
  return binary;
}

async function runSmoke(env: Record<string, string>) {
  const dir = mkdtempSync(join(tmpdir(), "cmux-ws-smoke-"));
  try {
    const binary = fakeCmuxTui(dir);
    const result = await runChild("bash", ["-c", cmuxTuiWebsocketSmokeScript()], {
      env: {
        ...process.env,
        HOME: dir,
        CMUX_TUI_BIN: binary,
        CMUX_TUI_SMOKE_ROOT: join(dir, "smoke"),
        ...env,
      },
      timeout: 30_000,
    });
    const approved = existsSync(join(dir, "approved")) ? readFileSync(join(dir, "approved"), "utf8").trim().split("\n") : [];
    return { ...result, approved };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("cmux-tui WebSocket smoke", () => {
  // Derive runs 42548063748 through 43402345356: the smoke slept a fixed 2 s
  // after approving, killed the connector, and the first RPC found no daemon.
  test("waits for a connector that records the daemon 3 s after the approval", async () => {
    const result = await runSmoke({ FAKE_PIN_DELAY: "3" });
    expect(result.stderr).not.toContain("no known daemon matches this route");
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/websocket-smoke-ok marker=CMUX_WS_SMOKE_cloud_\d+ through_sequence=1->1 timeline: connector=\+\d+ms pending=\+\d+ms approved=\+\d+ms pinned=\+\d+ms done=\+\d+ms/);
    const pinnedAfter = Number(/pinned=\+(\d+)ms/.exec(result.stdout)?.[1]) - Number(/approved=\+(\d+)ms/.exec(result.stdout)?.[1]);
    expect(pinnedAfter).toBeGreaterThanOrEqual(2_900);
  }, 30_000);

  test("approves its own pending request, not another device's listed first", async () => {
    const result = await runSmoke({});
    expect(result.status).toBe(0);
    expect(result.approved).toEqual(["ours"]);
  }, 30_000);

  test("a connector that never records the daemon fails with the timeline, not the route error", async () => {
    const result = await runSmoke({ FAKE_PIN_DELAY: "60", CMUX_TUI_SMOKE_PIN_TIMEOUT_SECONDS: "1" });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("the connector never recorded the daemon in its state dir, not within 1s of the approval");
    expect(result.stderr).toMatch(/timeline: connector=\+\d+ms pending=\+\d+ms approved=\+\d+ms gave-up=\+\d+ms/);
    expect(result.stderr).not.toContain("no known daemon matches this route");
  }, 30_000);

  test("a connector that exits before its request is pending fails at once with its stderr", async () => {
    const result = await runSmoke({ FAKE_CONNECT_FAIL: "dial refused" });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("the connector's enrollment request never appeared in the daemon's pending list");
    expect(result.stderr).toContain("connector: dial refused");
  }, 30_000);
});
