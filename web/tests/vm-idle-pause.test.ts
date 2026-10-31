import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  decideVmIdlePause,
  hasOutstandingPauseIntent,
  parseVmIdleProbe,
  vmIdleObservationFromRow,
  vmIdlePauseMinutesFromRow,
  vmIdlePrivateAddressesFromRow,
  vmIdleProbeCommand,
  vmLastApiActivityFromRow,
  vmPauseReasonFromRow,
  VM_IDLE_CPU_BUSY_CORES,
  VM_IDLE_OBSERVATION_MAX_GAP_MS,
  VM_IDLE_PAUSE_CHOICES,
  VM_IDLE_PAUSE_DEFAULT_MINUTES,
  VM_IDLE_PROBE_SCRIPT,
  type VmIdleObservation,
  type VmIdleProbe,
} from "../services/vms/idlePause";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmDatabaseError } from "../services/vms/errors";
import { pauseBudgetVm, pauseGoVm } from "../services/vms/goPause";
import { enforceVmIdlePause } from "../services/vms/idlePauseJob";
import { parseCreateIdlePause, parseIdlePauseBody } from "../services/vms/idlePauseRoute";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, vmRepositoryLiveShape, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { execVm, getVm, pauseVm, resizeVm, setVmIdlePause } from "../services/vms/workflows";
import { runChild } from "./helpers/run-child";

// Idle auto-pause (pilot blocker 1a). The decision is pure and pinned here: a
// machine running an agent turn, a foreground command, an attached client, an
// ssh login, a forwarded-port connection, CPU work or a recent API call is
// never idle; an unknown probe or a row without a private address never
// pauses; the timeout is respected; Off never pauses. The cron body runs
// against fake repository and provider layers, the guest probe script runs for
// real against a fake /proc, and the SQL runs against Postgres when
// CMUX_DB_TEST=1.

const MIN = 60_000;
const T0 = Date.parse("2026-10-21T12:00:00Z");
const VM = "fs-1";
/** A busy-CPU counter that does not move: an idle machine's CPU sample. */
const CPU0 = 4_000_000;

function idleProbe(overrides: Partial<VmIdleProbe> = {}): VmIdleProbe {
  return {
    daemon: { attachedClients: 0, liveAgents: 0, lastUserInputAt: null, lastAgentActionAt: null },
    acpmux: { busySessions: 0, lastUpdatedAt: null },
    busyTerminals: 0,
    sshSessions: 0,
    inboundConnections: 0,
    cpuBusyMs: CPU0,
    ...overrides,
  };
}

/** Runs the decision every 5 minutes from T0 for `forMinutes`, the way the cron does. */
function runCron(probeAt: (now: number) => VmIdleProbe | null, forMinutes: number, minutes = 30) {
  let previous: VmIdleObservation | null = null;
  for (let t = 0; t <= forMinutes; t += 5) {
    const now = T0 + t * MIN;
    const decision = decideVmIdlePause({ providerVmId: VM, minutes, probe: probeAt(now), previous, now });
    if (decision.pause) return { pausedAfterMinutes: t, decision };
    previous = decision.observation;
  }
  return { pausedAfterMinutes: null, decision: null };
}

describe("idle auto-pause default", () => {
  test("is on at 30 minutes, with the choices Off, 15, 30, 60 and 120", () => {
    expect(VM_IDLE_PAUSE_DEFAULT_MINUTES).toBe(30);
    expect([...VM_IDLE_PAUSE_CHOICES]).toEqual([0, 15, 30, 60, 120]);
  });

  test("a machine without its own setting gets the default; its own setting wins; junk is ignored", () => {
    expect(vmIdlePauseMinutesFromRow({ providerMetadata: {} })).toBe(30);
    expect(vmIdlePauseMinutesFromRow({ providerMetadata: null })).toBe(30);
    expect(vmIdlePauseMinutesFromRow({ providerMetadata: { cmuxIdlePauseMinutes: 0 } })).toBe(0);
    expect(vmIdlePauseMinutesFromRow({ providerMetadata: { cmuxIdlePauseMinutes: 120 } })).toBe(120);
    expect(vmIdlePauseMinutesFromRow({ providerMetadata: { cmuxIdlePauseMinutes: 45 } })).toBe(30);
    expect(vmIdlePauseMinutesFromRow({ providerMetadata: { cmuxIdlePauseMinutes: "15" } })).toBe(30);
  });
});

describe("idle decision", () => {
  test("a running agent turn is never idle, however long it runs", () => {
    const turn = idleProbe({ acpmux: { busySessions: 1, lastUpdatedAt: null } });
    expect(runCron(() => turn, 6 * 60).pausedAfterMinutes).toBeNull();
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: turn, previous: null, now: T0 }).reason).toBe("active:agent_turns");
    const hookAgent = idleProbe({ daemon: { attachedClients: 0, liveAgents: 1, lastUserInputAt: null, lastAgentActionAt: null } });
    expect(runCron(() => hookAgent, 6 * 60).pausedAfterMinutes).toBeNull();
  });

  test("a foreground command, an ssh login or a forwarded-port connection keeps it awake", () => {
    const cases: Array<[VmIdleProbe, string]> = [
      [idleProbe({ busyTerminals: 1 }), "active:busy_terminals"],
      [idleProbe({ sshSessions: 1 }), "active:ssh_sessions"],
      [idleProbe({ inboundConnections: 2 }), "active:inbound_connections"],
    ];
    for (const [probe, reason] of cases) {
      expect(runCron(() => probe, 6 * 60).pausedAfterMinutes).toBeNull();
      expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe, previous: null, now: T0 })).toEqual({ pause: false, reason, observation: null });
    }
  });

  test("an attached app with nobody typing pauses after the timeout; typing into it keeps it awake", () => {
    // The Mac app stays attached for days (it re-attaches after every daemon restart), so
    // attachment is not activity: a person's input through it is.
    const attached = (lastUserInputAt: number | null) =>
      idleProbe({ daemon: { attachedClients: 2, liveAgents: 0, lastUserInputAt, lastAgentActionAt: null } });
    expect(runCron(() => attached(null), 120).pausedAfterMinutes).toBe(30);
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: attached(null), previous: null, now: T0 }).reason).toBe("idle");
    // Typing every minute through the attached app: never idle for 30 minutes.
    expect(runCron((now) => attached(now - MIN), 6 * 60).pausedAfterMinutes).toBeNull();
    // The person stops typing at minute 40: paused 30 minutes later, at the next probe.
    expect(runCron((now) => attached(Math.min(now, T0 + 40 * MIN)), 6 * 60).pausedAfterMinutes).toBe(70);
  });

  test("activity in the middle of the stretch starts it over", () => {
    // Idle, then a build runs at minute 20, then idle again: 30 minutes from the last busy probe.
    const result = runCron((now) => (now === T0 + 20 * MIN ? idleProbe({ busyTerminals: 1 }) : idleProbe()), 120);
    expect(result.pausedAfterMinutes).toBe(55);
  });

  test("the timeout is respected: idle from the first idle probe, paused once 30 minutes have passed", () => {
    expect(runCron(() => idleProbe(), 120).pausedAfterMinutes).toBe(30);
    expect(runCron(() => idleProbe(), 120, 15).pausedAfterMinutes).toBe(15);
    expect(runCron(() => idleProbe(), 120, 60).pausedAfterMinutes).toBe(60);
    // The first idle probe never pauses, even when the reported times are hours old.
    const old = idleProbe({ daemon: { attachedClients: 0, liveAgents: 0, lastUserInputAt: T0 - 5 * 60 * MIN, lastAgentActionAt: null } });
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: old, previous: null, now: T0 }).pause).toBe(false);
  });

  test("input, an agent action or an acpmux session change between probes counts as activity", () => {
    const at = (field: "input" | "agent" | "acpmux", ms: number) => idleProbe({
      daemon: { attachedClients: 0, liveAgents: 0, lastUserInputAt: field === "input" ? ms : null, lastAgentActionAt: field === "agent" ? ms : null },
      acpmux: { busySessions: 0, lastUpdatedAt: field === "acpmux" ? ms : null },
    });
    for (const field of ["input", "agent", "acpmux"] as const) {
      // Activity at minute 22 (between the 20 and 25 probes): the pause waits until minute 52 has passed.
      const result = runCron((now) => at(field, now >= T0 + 25 * MIN ? T0 + 22 * MIN : T0 - MIN), 120);
      expect(result.pausedAfterMinutes).toBe(55);
    }
    // A time from a clock ahead of ours is never later than now.
    const ahead = at("input", T0 + 10 * 60 * MIN);
    const previous = { providerVmId: VM, idleSince: T0 - 40 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: ahead, previous, now: T0 }).pause).toBe(false);
  });

  test("an unknown probe never pauses and does not carry the stretch", () => {
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    for (const [probe, reason] of [
      [null, "unknown:probe"],
      [idleProbe({ daemon: null }), "unknown:daemon"],
      [idleProbe({ acpmux: null }), "unknown:acpmux"],
    ] as const) {
      expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe, previous, now: T0 })).toEqual({ pause: false, reason, observation: null });
    }
    // Idle, then the probe fails once: the stretch starts again after it.
    expect(runCron((now) => (now === T0 + 15 * MIN ? null : idleProbe()), 120).pausedAfterMinutes).toBe(50);
  });

  test("a gap in the observations (a pause, missed runs) starts the stretch over", () => {
    const stale = { providerVmId: VM, idleSince: T0 - 120 * MIN, observedAt: T0 - VM_IDLE_OBSERVATION_MAX_GAP_MS - 1, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: stale, now: T0 })).toEqual({
      pause: false, reason: "idle", observation: { providerVmId: VM, idleSince: T0, observedAt: T0, cpuBusyMs: CPU0 },
    });
    const otherVm = { providerVmId: "fs-other", idleSince: T0 - 120 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: otherVm, now: T0 }).pause).toBe(false);
    const fresh = { providerVmId: VM, idleSince: T0 - 30 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: fresh, now: T0 }).pause).toBe(true);
  });

  test("Off never pauses, even idle for days", () => {
    expect(runCron(() => idleProbe(), 3 * 24 * 60, 0).pausedAfterMinutes).toBeNull();
    const previous = { providerVmId: VM, idleSince: T0 - 3 * 24 * 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 0, probe: idleProbe(), previous, now: T0 })).toEqual({ pause: false, reason: "off", observation: null });
  });
});

describe("idle probe output", () => {
  test("parses the probe's last line and rejects anything malformed", () => {
    const line = JSON.stringify({
      v: 1,
      daemon: { attached_clients: 0, live_agents: 2, last_user_input_at_ms: 1_700_000_000_000, last_agent_action_at_ms: null },
      acpmux: { busy_sessions: 1, last_updated_at_ms: 1_700_000_000_500 },
      busy_terminals: 3,
      ssh_sessions: 0,
      inbound_connections: 1,
    });
    expect(parseVmIdleProbe(`banner\n${line}\n`)).toEqual({
      daemon: { attachedClients: 0, liveAgents: 2, lastUserInputAt: 1_700_000_000_000, lastAgentActionAt: null },
      acpmux: { busySessions: 1, lastUpdatedAt: 1_700_000_000_500 },
      busyTerminals: 3,
      sshSessions: 0,
      inboundConnections: 1,
    });
    expect(parseVmIdleProbe(JSON.stringify({ v: 1, daemon: null, acpmux: null, busy_terminals: 0, ssh_sessions: 0, inbound_connections: 0 })))
      .toMatchObject({ daemon: null, acpmux: null });
    expect(parseVmIdleProbe("")).toBeNull();
    expect(parseVmIdleProbe("not json")).toBeNull();
    expect(parseVmIdleProbe(JSON.stringify({ v: 2, busy_terminals: 0, ssh_sessions: 0, inbound_connections: 0 }))).toBeNull();
    expect(parseVmIdleProbe(JSON.stringify({ v: 1, busy_terminals: -1, ssh_sessions: 0, inbound_connections: 0 }))).toBeNull();
    expect(parseVmIdleProbe(JSON.stringify({ v: 1, busy_terminals: 0, ssh_sessions: 0 }))).toBeNull();
  });

  test("the probe command runs acpmux as the daemon user only when its daemon runs, and passes only IP literals", () => {
    const command = vmIdleProbeCommand(["10.192.0.5", "fd00:7::5", "10.0.0.1; rm -rf /", "10.192.0.999"]);
    expect(command).toContain(`CMUX_IDLE_PRIVATE_ADDRESSES='10.192.0.5,fd00:7::5'`);
    expect(command).toContain(`acp --json daemon status`);
    expect(command).toContain(`*'"running":false'*`);
    expect(command).toContain("setpriv");
    expect(command).not.toContain("rm -rf");
    expect(command).not.toContain("10.192.0.999");
  });
});

/** A fake /proc and daemon socket file for the guest script. */
function fakeProc(files: Record<string, string>): string {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-idle-proc-"));
  for (const [rel, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    // A process's open file is a symlink like /proc/<pid>/fd/7 -> socket:[4242].
    if (/\/fd\/\d+$/.test(rel)) symlinkSync(text, path.join(root, rel));
    else writeFileSync(path.join(root, rel), text);
  }
  return root;
}

const PTS0 = (136 << 8) | 0;
const PTS1 = (136 << 8) | 1;
const TTYS0 = (4 << 8) | 64;
const stat = (pid: number, comm: string, pgrp: number, sid: number, tty: number, tpgid: number) =>
  `${pid} (${comm}) S 1 ${pgrp} ${sid} ${tty} ${tpgid} 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0\n`;
const TCP_HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";
const tcpRow = (local: string, remote: string, state: string, inode = 1) =>
  `   0: ${local} ${remote} ${state} 00000000:00000000 00:00000000 00000000  1000        0 ${inode} 1\n`;
// 10.192.0.5 little-endian, ports 1337 (0539), 3000 (0BB8), 22 (0016).
const VPC = "0500C00A";
const LO = "0100007F";
/**
 * 127.0.0.1:3000 (a dev server) listening; the daemon (pid 500) holds the
 * client end of a stream to it, opened for the app's loopback-forward-v1 over
 * its link on :1337.
 */
const FORWARDED_PORT_PROC = {
  "500/stat": stat(500, "cmux-tui", 500, 500, 0, -1),
  "500/fd/7": "socket:[4242]",
  "600/stat": stat(600, "node", 600, 600, 0, -1),
  "600/fd/9": "socket:[4243]",
  "net/tcp": TCP_HEADER
    + tcpRow(`${LO}:0BB8`, "00000000:0000", "0A")
    + tcpRow(`00000000:0539`, "00000000:0000", "0A")
    + tcpRow(`${VPC}:0539`, "0900C00A:D432", "01", 77)
    + tcpRow(`${LO}:D500`, `${LO}:0BB8`, "01", 4242)
    + tcpRow(`${LO}:0BB8`, `${LO}:D500`, "01", 4243),
  "net/tcp6": TCP_HEADER,
};

async function runProbeScript(
  files: Record<string, string>,
  acpmux: string,
  options: { readonly acpmuxStatusError?: string; readonly daemonSocket?: string } = {},
): Promise<Record<string, unknown>> {
  const root = fakeProc(files);
  writeFileSync(path.join(root, "acpmux.json"), acpmux);
  writeFileSync(path.join(root, "acpmux.err"), options.acpmuxStatusError ?? "");
  writeFileSync(path.join(root, "daemon-socket"), options.daemonSocket ?? path.join(root, "no-such.sock"));
  const result = await runChild("python3", ["-I", "-c", VM_IDLE_PROBE_SCRIPT], {
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      CMUX_IDLE_PROC_ROOT: root,
      CMUX_IDLE_ACPMUX: path.join(root, "acpmux.json"),
      CMUX_IDLE_ACPMUX_ERR: path.join(root, "acpmux.err"),
      CMUX_IDLE_DAEMON_SOCKET_FILE: path.join(root, "daemon-socket"),
      CMUX_IDLE_PRIVATE_ADDRESSES: "10.192.0.5,fd00:7::5",
      CMUX_IDLE_DAEMON_PORT: "1337",
    },
    timeout: 30_000,
  });
  expect(result.error).toBeUndefined();
  expect(result.status).toBe(0);
  return JSON.parse(result.stdout.trim().split("\n").at(-1) ?? "{}");
}

describe("idle probe guest script", () => {
  test("counts a terminal running a command, never a shell at its prompt or a serial console", async () => {
    const out = await runProbeScript({
      // pts/0: zsh at its prompt (the foreground group is the shell's own).
      "100/stat": stat(100, "zsh", 100, 100, PTS0, 100),
      "100/cmdline": "-zsh\0",
      // pts/1: bash running `npm run dev` (node is the foreground group).
      "200/stat": stat(200, "bash", 200, 200, PTS1, 210),
      "210/stat": stat(210, "node", 210, 200, PTS1, 210),
      "210/cmdline": "node\0server.js\0",
      // ttyS0: agetty is in the foreground of a serial console, not a pseudo-terminal.
      "300/stat": stat(300, "agetty", 300, 300, TTYS0, 300),
      // An sshd session for a logged-in user, and its unauthenticated listener.
      "400/stat": stat(400, "sshd", 400, 400, 0, -1),
      "400/cmdline": "sshd: cmux@pts/2\0",
      "401/stat": stat(401, "sshd", 401, 401, 0, -1),
      "401/cmdline": "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups\0",
      "net/tcp": TCP_HEADER
        + tcpRow(`00000000:0539`, "00000000:0000", "0A")
        + tcpRow(`00000000:0BB8`, "00000000:0000", "0A")
        // A forwarded port in use: 10.192.0.9 -> 10.192.0.5:3000.
        + tcpRow(`${VPC}:0BB8`, "0900C00A:D431", "01")
        // The machine's own outbound connection (local port not listening): not counted.
        + tcpRow(`${VPC}:9C40`, "08080808:01BB", "01")
        // The app's link to the daemon (ws://[vpc]:1337): the daemon reports its
        // input itself, and an attached app with nobody typing is not activity.
        + tcpRow(`${VPC}:0539`, "0900C00A:D432", "01")
        // A loopback connection to the daemon port: not on the private address, not counted.
        + tcpRow(`0100007F:0539`, "0100007F:D000", "01"),
      "net/tcp6": TCP_HEADER,
    }, JSON.stringify({ sessions: [
      { name: "lane", status: "running", turn: { id: 1 }, updatedAt: 1_700_000_000_000 },
      { name: "done", status: "ready", turn: null, updatedAt: 1_700_000_005_000 },
      { name: "asks", status: "waiting", turn: null, pendingPermissions: 1, updatedAt: 1 },
      { name: "peer", status: "running", peer: "huge-blue", updatedAt: 1_800_000_000_000 },
    ] }));
    expect(out).toEqual({
      v: 1,
      daemon: null,
      acpmux: { busy_sessions: 2, last_updated_at_ms: 1_700_000_005_000 },
      busy_terminals: 1,
      ssh_sessions: 1,
      inbound_connections: 1,
      cpu_busy_ms: null,
    });
  });

  test("with no daemon-socket file (images baked before it), the daemon is found at its session socket", async () => {
    const root = fakeProc({ "net/tcp": TCP_HEADER, "net/tcp6": TCP_HEADER });
    const dir = path.join(root, "tmp", "cmux-tui-1000");
    mkdirSync(dir, { recursive: true });
    const socketPath = path.join(dir, "cloud.sock");
    const server = createServer((conn) => {
      conn.once("data", (line) => {
        expect(String(line)).toContain('"subscribe-activity"');
        conn.end(JSON.stringify({ id: 1, ok: true, data: { activity: { attached_clients: 1, live_agents: 0, last_user_input_at_ms: 1_700_000_000_000, last_agent_action_at_ms: null } } }) + "\n");
      });
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    try {
      writeFileSync(path.join(root, "acpmux.json"), "NONE");
      const result = await runChild("python3", ["-I", "-c", VM_IDLE_PROBE_SCRIPT], {
        env: {
          PATH: process.env.PATH ?? "/usr/bin:/bin",
          CMUX_IDLE_PROC_ROOT: root,
          CMUX_IDLE_ACPMUX: path.join(root, "acpmux.json"),
          CMUX_IDLE_DAEMON_SOCKET_FILE: path.join(root, "no-daemon-socket-file"),
          CMUX_IDLE_DAEMON_UID: "1000",
          CMUX_IDLE_DAEMON_SOCKET_ROOTS: `${path.join(root, "run-user-1000")}:${path.join(root, "tmp")}`,
        },
        timeout: 30_000,
      });
      expect(result.status).toBe(0);
      expect(JSON.parse(result.stdout.trim().split("\n").at(-1) ?? "{}").daemon).toEqual({
        attached_clients: 1, live_agents: 0, last_user_input_at_ms: 1_700_000_000_000, last_agent_action_at_ms: null,
      });
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("the probe command passes the daemon user's uid for the session socket", () => {
    expect(vmIdleProbeCommand(["10.192.0.5"])).toContain(`CMUX_IDLE_DAEMON_UID="$(id -u "$CMUX_TUI_USER")"`);
    expect(vmIdleProbeCommand(["10.192.0.5"])).toContain("CMUX_IDLE_DAEMON_PORT=1337");
  });

  test("the probe runs python isolated: as root, nothing on the machine's path or environment is imported", () => {
    expect(vmIdleProbeCommand(["10.192.0.5"])).toContain("python3 -I -");
  });

  test("a port the app forwards through the daemon link is in use while the daemon holds a stream to it", async () => {
    expect((await runProbeScript(FORWARDED_PORT_PROC, "NONE")).inbound_connections).toBe(1);
    // The same loopback stream held by another process (not the daemon) is the machine talking to itself.
    const local = { ...FORWARDED_PORT_PROC, "500/fd/7": "socket:[1]", "600/fd/8": "socket:[4242]" };
    expect((await runProbeScript(local, "NONE")).inbound_connections).toBe(0);
  });

  test("an idle machine reads all zeros; a stopped acpmux is none; an unreadable one is unknown", async () => {
    const idle = {
      "100/stat": stat(100, "bash", 100, 100, PTS0, 100),
      "net/tcp": TCP_HEADER + tcpRow(`00000000:0539`, "00000000:0000", "0A"),
      "net/tcp6": TCP_HEADER,
    };
    expect(await runProbeScript(idle, "NONE")).toMatchObject({
      acpmux: { busy_sessions: 0, last_updated_at_ms: null }, busy_terminals: 0, ssh_sessions: 0, inbound_connections: 0,
    });
    expect((await runProbeScript(idle, "ERR")).acpmux).toBeNull();
    expect((await runProbeScript(idle, JSON.stringify({ sessions: [{ name: "a", status: "ready", turn: null }] }))).acpmux)
      .toEqual({ busy_sessions: 0, last_updated_at_ms: null });
  });

  test("durable acpmux queues, waiting slots, questions and transfers protect a ready session", async () => {
    // acpmux session_list_summary serializes queued, queuePaused, waitsForSlot, moving,
    // and waitingOn independently from status/turn. A queued message is work.
    for (const marker of [
      { queued: 1 },
      { queuePaused: true },
      { waitsForSlot: true },
      { moving: true },
      { waitingOn: "question" },
    ]) {
      const out = await runProbeScript({
        "net/tcp": TCP_HEADER, "net/tcp6": TCP_HEADER,
      }, JSON.stringify({ sessions: [
        { name: "idle-but-queued", status: "ready", turn: null, pendingPermissions: 0, queued: 0, ...marker },
      ] }));
      expect({ marker, acpmux: out.acpmux }).toEqual({
        marker, acpmux: { busy_sessions: 1, last_updated_at_ms: null },
      });
      expect(parseVmIdleProbe(JSON.stringify(out))?.acpmux?.busySessions).toBe(1);
    }
    const idle = await runProbeScript({ "net/tcp": TCP_HEADER }, JSON.stringify({
      sessions: [{ name: "ready", status: "ready", turn: null, queued: 0 }],
    }));
    expect(idle.acpmux).toEqual({ busy_sessions: 0, last_updated_at_ms: null });
  });

  test("a malformed acpmux queued count is unknown rather than zero", async () => {
    const out = await runProbeScript({ "net/tcp": TCP_HEADER }, JSON.stringify({
      sessions: [{ name: "broken", status: "ready", turn: null, queued: "1" }],
    }));
    expect(out.acpmux).toBeNull();
  });

  test("counts an IPv6 connection to the private address, a v4-mapped one, and any connection into sshd", async () => {
    // fd00:7::5 in /proc/net/tcp6 word order; a remote fd00:7::9.
    const local6 = "070000FD000000000000000005000000";
    const remote6 = "070000FD000000000000000009000000";
    const mapped = "0000000000000000FFFF00000500C00A";
    const out = await runProbeScript({
      "net/tcp": TCP_HEADER
        + tcpRow(`00000000:0016`, "00000000:0000", "0A")
        // ssh through the link arrives on loopback: counted because it is sshd.
        + tcpRow(`0100007F:0016`, "0100007F:E000", "01"),
      "net/tcp6": TCP_HEADER
        + tcpRow(`00000000000000000000000000000000:0BB8`, "00000000000000000000000000000000:0000", "0A")
        + tcpRow(`${local6}:0BB8`, `${remote6}:C000`, "01")
        + tcpRow(`${mapped}:0BB8`, "0000000000000000FFFF00000900C00A:C001", "01"),
    }, "NONE");
    expect(out.inbound_connections).toBe(3);
  });

  test("an unreadable TCP table makes inbound activity unknown; an absent tcp6 alone is valid", async () => {
    const noTcp = await runProbeScript({ "net/tcp6": TCP_HEADER }, "NONE");
    expect(noTcp.inbound_connections).toBeNull();
    expect(parseVmIdleProbe(JSON.stringify(noTcp))).toBeNull();
    const noIpv6 = await runProbeScript({ "net/tcp": TCP_HEADER }, "NONE");
    expect(noIpv6.inbound_connections).toBe(0);
  });

  test("a malformed IPv4 or IPv6 TCP row is unknown, never an empty connection list", async () => {
    for (const files of [
      { "net/tcp": TCP_HEADER + "0: truncated\n", "net/tcp6": TCP_HEADER },
      { "net/tcp": TCP_HEADER, "net/tcp6": TCP_HEADER + tcpRow("invalid:0BB8", "00000000:0000", "01") },
    ]) {
      const out = await runProbeScript(files, "NONE");
      expect(out.inbound_connections).toBeNull();
      expect(parseVmIdleProbe(JSON.stringify(out))).toBeNull();
    }
  });
});

function machineRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "row-1",
    userId: "user-1",
    billingTeamId: "team-1",
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: VM,
    displayName: null,
    slug: "brave-otter",
    imageId: "sh-devbox",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: new Date("2026-09-01T00:00:00Z"),
    updatedAt: new Date("2026-09-01T00:00:00Z"),
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: { networkIpv4: "10.192.0.5" },
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ...overrides,
  };
}

type ObservedStatusInput = Parameters<VmRepositoryShape["markProviderObservedStatus"]>[0];

function omit(metadata: Record<string, unknown>, key: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(metadata).filter(([k]) => k !== key));
}

function withoutObservation(metadata: Record<string, unknown>): Record<string, unknown> {
  return omit(metadata, "cmuxIdleObservation");
}

/** The row's idle fence (repository.ts cmuxIdleEpoch); 0 when never written. */
function epochOf(row: CloudVmRow): number {
  const stored = row.providerMetadata?.cmuxIdleEpoch;
  return typeof stored === "number" ? stored : 0;
}

/** Metadata with the fence moved on, as every write that can change the idle verdict does. */
function bumped(row: CloudVmRow, metadata: Record<string, unknown> = row.providerMetadata ?? {}): Record<string, unknown> {
  return { ...metadata, cmuxIdleEpoch: epochOf(row) + 1 };
}

/** What the live markProviderObservedStatus leaves in providerMetadata (repository.ts observedStatusMetadata). */
function observedStatusMetadata(metadata: Record<string, unknown>, input: ObservedStatusInput, nextEpoch: number): Record<string, unknown> {
  // A claim is settled only by a decision (a stated pause), the cron's own fenced write, or a destroy;
  // the status reconciler's write keeps it for the cron to resolve.
  const settles = input.pauseReason !== undefined || input.expectIdleEpoch !== undefined || input.status === "destroyed";
  const base = settles ? omit(withoutObservation(metadata), "cmuxIdlePauseClaim") : withoutObservation(metadata);
  if (input.status !== "paused") return omit(omit(base, "cmuxPauseReason"), "cmuxPauseIntentEpoch");
  // A pause that says why is someone's decision, stamped with the fence it set; the status reconciler's write says nothing.
  return input.pauseReason ? { ...omit(base, "cmuxPendingPause"), cmuxPauseReason: input.pauseReason, cmuxPauseIntentEpoch: nextEpoch } : base;
}

/**
 * Fake repository and provider layers. The repository mirrors the live writes
 * on `rows`: a status write drops the idle observation, the cron's write
 * stores the observation and the check time, and `resume` does what
 * reservePausedResume does. Every write that can change the idle verdict moves
 * the row's fence (cmuxIdleEpoch), and the cron's fenced writes lose when it
 * moved, like the live SQL. `reread` changes what the pre-pause re-read sees;
 * `duringProbe` and `duringPause` run other writers while the probe or the
 * provider pause is under way.
 */
/** What a hook can do to the world mid-run. A hook may return an Effect, which runs in place. */
type FakeContext = {
  /** A person's Pause Machine, through the real pause path (pauseVm). */
  readonly userPause: (id: string) => Effect.Effect<void>;
  readonly reconcilerSees: (id: string, status: "paused" | "running") => void;
  readonly providerState: Map<string, "running" | "paused">;
};

type FakeHook = (repo: VmRepositoryShape, ctx: FakeContext) => unknown;

function cronFakes(
  rows: CloudVmRow[],
  probeOut: (vmId: string, call: number) => { exitCode: number; stdout: string } | "fails",
  fakeOptions: {
    readonly reread?: (row: CloudVmRow) => CloudVmRow | null;
    readonly duringProbe?: (repo: VmRepositoryShape, ctx: FakeContext) => void;
    readonly duringPause?: FakeHook;
    /** Runs inside the compensating resume's fence claim, before it checks the fence. */
    readonly beforeResumeClaim?: FakeHook;
    /** Runs inside each provider status read, before it answers. */
    readonly duringStatus?: FakeHook;
    /** Runs inside each provider status read, after it has its answer (the caller acts on a stale read). */
    readonly afterStatus?: FakeHook;
    /** Runs inside a later (plain) provider pause before it lands: an Effect here holds that pause in flight. */
    readonly holdPause?: () => Effect.Effect<void> | undefined;
    /** Runs right after the provider resumes, before the caller records it. */
    readonly afterResume?: FakeHook;
    /** Runs right after a compensating resume's fence claim succeeds. */
    readonly afterResumeClaim?: FakeHook;
    /** Every runtime cap write but the pause's own zero fails. */
    readonly budgetFails?: boolean;
    /** "accepted": the provider pauses, then the call errors (a lost answer); "refused": it errors without pausing. */
    readonly pauseFails?: "accepted" | "refused";
    /** How many provider status reads fail before they answer. */
    readonly statusFailures?: number;
  } = {},
) {
  const recorded = {
    execs: [] as Array<{ vmId: string; asRoot: boolean | undefined; command: string; cancelOnInterrupt?: boolean }>,
    paused: [] as string[],
    statuses: [] as Array<{ id: string; status: string; pauseReason?: string }>,
    observations: [] as Array<{ id: string; observation: VmIdleObservation | null }>,
    probedAt: [] as Array<{ id: string; probedAt: number }>,
    apiActivity: [] as Array<{ id: string; at: number }>,
    events: [] as Array<Record<string, unknown>>,
    minutes: [] as Array<{ id: string; minutes: number }>,
    resumed: [] as string[],
    /** Provider runtime budgets set, in order (a Go machine's pause zeroes it). */
    budgets: [] as Array<number | null>,
    /** Provider calls and recorded writes, in order: budget:N, resume, status:S, observation. */
    log: [] as string[],
  };
  const providerState = new Map<string, "running" | "paused">();
  const probeCalls = new Map<string, number>();
  let statusFailures = fakeOptions.statusFailures ?? 0;
  const ctx = { providerState } as { -readonly [K in keyof FakeContext]: FakeContext[K] };
  const runHook = (hook: FakeHook | undefined): Effect.Effect<void> => Effect.suspend(() => {
    const out = hook?.(repo, ctx);
    return Effect.isEffect(out) ? Effect.asVoid(out as Effect.Effect<unknown>) : Effect.void;
  });
  const fenced = (row: CloudVmRow, epoch: number | undefined) => epoch === undefined || epochOf(row) === epoch;
  const update = (id: string, change: (row: CloudVmRow) => CloudVmRow) => {
    const index = rows.findIndex((r) => r.id === id);
    if (index >= 0) rows[index] = change(rows[index]);
  };
  const repo = {
    // Like the live query: running machines only.
    // Like the live query: running machines, and any live row still holding an idle pause claim.
    idlePauseCandidates: () => Effect.sync(() => rows.filter((r) => r.status === "running" || (r.status !== "destroyed" && r.providerMetadata?.cmuxIdlePauseClaim !== undefined))),
    recordIdleDecision: (input: { id: string; providerVmId: string; checkId: string; decision: { at: number; outcome: string; reason: string; run: { checked: number; elapsedMs: number } } }) => Effect.sync(() => {
      update(input.id, (row) => {
        if (row.providerVmId !== input.providerVmId) return row;
        const previous = row.providerMetadata?.cmuxIdleLastDecision as { at: number; checkId: string } | undefined;
        if (previous && previous.at > input.decision.at) return row;
        if (previous && previous.at === input.decision.at && previous.checkId !== input.checkId) return row;
        return { ...row, providerMetadata: { ...row.providerMetadata, cmuxIdleLastDecision: { ...input.decision, checkId: input.checkId },
          cmuxIdleProbedAt: Math.max(Number(row.providerMetadata?.cmuxIdleProbedAt) || 0, input.decision.at) } };
      });
    }),
    recordIdleObservation: (input: { id: string; providerVmId: string; observation: VmIdleObservation | null; probedAt: number; epoch?: number }) => Effect.sync(() => {
      recorded.observations.push({ id: input.id, observation: input.observation });
      recorded.probedAt.push({ id: input.id, probedAt: input.probedAt });
      let won = false;
      update(input.id, (row) => {
        if (row.status !== "running" || row.providerVmId !== input.providerVmId || !fenced(row, input.epoch)) return row;
        won = true;
        recorded.log.push("observation");
        return {
          ...row,
          providerMetadata: bumped(row, {
            ...omit(withoutObservation(row.providerMetadata ?? {}), "cmuxIdlePauseClaim"),
            ...(input.observation ? { cmuxIdleObservation: input.observation } : {}),
            cmuxIdleProbedAt: input.probedAt,
          }),
        };
      });
      return won;
    }),
    claimIdlePause: (input: { id: string; providerVmId: string; epoch: number }) => Effect.sync(() => {
      let claimed: number | null = null;
      update(input.id, (row) => {
        if (row.status !== "running" || row.providerVmId !== input.providerVmId || epochOf(row) !== input.epoch) return row;
        if (hasOutstandingPauseIntent(row, Date.now())) return row;
        claimed = input.epoch + 1;
        return { ...row, providerMetadata: bumped(row, { ...(row.providerMetadata ?? {}), cmuxIdlePauseClaim: input.epoch + 1 }) };
      });
      return claimed;
    }),
    claimIdleResume: (input: { id: string; providerVmId: string; epoch: number }) => runHook(fakeOptions.beforeResumeClaim).pipe(Effect.andThen(Effect.sync(() => {
      let claimed: number | null = null;
      update(input.id, (row) => {
        if (row.status === "destroyed" || row.providerVmId !== input.providerVmId || epochOf(row) !== input.epoch) return row;
        if (hasOutstandingPauseIntent(row, Date.now())) return row;
        claimed = input.epoch + 1;
        return { ...row, providerMetadata: bumped(row) };
      });
      return claimed;
    })), Effect.tap((claimed) => (claimed === null ? Effect.void : runHook(fakeOptions.afterResumeClaim)))),
    recordVmApiActivity: (input: { id: string; providerVmId: string; at: number }) => Effect.sync(() => {
      recorded.apiActivity.push({ id: input.id, at: input.at });
      update(input.id, (row) => ({ ...row, providerMetadata: bumped(row, { ...(row.providerMetadata ?? {}), cmuxLastApiActivityAt: input.at }) }));
      return true;
    }),
    reservePausedResume: (input: { id: string }) => Effect.sync(() => {
      update(input.id, (row) => row.status !== "paused" ? row : {
        ...row,
        status: "running",
        updatedAt: new Date(row.updatedAt.getTime() + 1),
        providerMetadata: bumped(row, observedStatusMetadata(row.providerMetadata ?? {}, { id: row.id, providerVmId: row.providerVmId ?? "", status: "running" }, 0)),
      });
      return rows.find((r) => r.id === input.id) ?? null;
    }),
    findUserVm: (input: { providerVmId: string }) => Effect.sync(() => {
      const row = rows.find((r) => r.providerVmId === input.providerVmId && r.status !== "destroyed") ?? null;
      return row && fakeOptions.reread ? fakeOptions.reread(row) : row;
    }),
    markProviderObservedStatus: (input: ObservedStatusInput & { expectIdleEpoch?: number }) => Effect.sync(() => {
      const row = rows.find((r) => r.id === input.id);
      if (!row || row.providerVmId !== input.providerVmId || row.status === "destroyed") return false;
      if (input.expectIdleEpoch !== undefined && epochOf(row) !== input.expectIdleEpoch) return false;
      recorded.statuses.push({ id: input.id, status: input.status, ...(input.pauseReason ? { pauseReason: input.pauseReason } : {}) });
      recorded.log.push(`status:${input.status}`);
      update(input.id, (current) => ({
        ...current,
        status: input.status,
        updatedAt: new Date(current.updatedAt.getTime() + 1),
        providerMetadata: bumped(current, observedStatusMetadata(current.providerMetadata ?? {}, input, epochOf(current) + 1)),
      }));
      return true;
    }),
    recordUsageEvent: (input: { metadata?: Record<string, unknown> }) => {
      recorded.events.push(input.metadata ?? {});
      return Effect.void;
    },
    recordPauseIntent: (input: { id: string; providerVmId: string; cause: string }) => Effect.sync(() => {
      const row = rows.find((r) => r.id === input.id);
      if (!row || row.providerVmId !== input.providerVmId || row.status === "destroyed") return null;
      const epoch = epochOf(row) + 1;
      update(input.id, (current) => ({
        ...current,
        providerMetadata: bumped(current, { ...(current.providerMetadata ?? {}), cmuxPendingPause: { cause: input.cause, epoch, requestedAt: Date.now() } }),
      }));
      return epoch;
    }),
    clearPauseIntent: (input: { id: string; epoch: number }) => Effect.sync(() => {
      update(input.id, (row) => {
        const pending = row.providerMetadata?.cmuxPendingPause as { epoch?: number } | undefined;
        return pending?.epoch === input.epoch ? { ...row, providerMetadata: omit(row.providerMetadata ?? {}, "cmuxPendingPause") } : row;
      });
    }),
    mergeProviderMetadata: (input: { id: string; patch: Record<string, unknown> }) => Effect.sync(() => {
      update(input.id, (row) => ({ ...row, providerMetadata: { ...(row.providerMetadata ?? {}), ...input.patch } }));
    }),
    setIdlePauseMinutes: (input: { id: string; minutes: number }) => Effect.sync(() => {
      recorded.minutes.push(input);
      update(input.id, (row) => ({ ...row, providerMetadata: bumped(row, { ...(row.providerMetadata ?? {}), cmuxIdlePauseMinutes: input.minutes }) }));
    }),
  } as unknown as VmRepositoryShape;
  const provider = {
    exec: (_provider: string, vmId: string, command: string, options?: { asRoot?: boolean; cancelOnInterrupt?: boolean }) => {
      recorded.execs.push({ vmId, asRoot: options?.asRoot, command, cancelOnInterrupt: options?.cancelOnInterrupt });
      const call = probeCalls.get(vmId) ?? 0;
      probeCalls.set(vmId, call + 1);
      if (call === 0) fakeOptions.duringProbe?.(repo, ctx);
      const out = probeOut(vmId, call);
      return out === "fails" ? Effect.fail(new Error("exec failed")) : Effect.succeed({ ...out, stderr: "" });
    },
    pause: (_provider: string, vmId: string) => Effect.suspend(() => {
      const paused = recorded.paused.length;
      recorded.paused.push(vmId);
      // Only the cron's first provider pause fails or runs the hook; a later re-pause is plain.
      if (paused > 0) return (fakeOptions.holdPause?.() ?? Effect.void).pipe(Effect.andThen(Effect.sync(() => providerState.set(vmId, "paused"))));
      if (fakeOptions.pauseFails !== "refused") providerState.set(vmId, "paused");
      return runHook(fakeOptions.duringPause).pipe(
        Effect.andThen(fakeOptions.pauseFails ? Effect.fail(new Error("pause: connection reset")) : Effect.void),
      );
    }),
    getStatus: (_provider: string, vmId: string) => runHook(fakeOptions.duringStatus).pipe(Effect.andThen(Effect.suspend(() => {
      if (statusFailures > 0) {
        statusFailures -= 1;
        return Effect.fail(new Error("status: timed out"));
      }
      const answer = providerState.get(vmId) ?? "running";
      return runHook(fakeOptions.afterStatus).pipe(Effect.as(answer));
    }))),
    setRuntimeBudget: (_provider: string, _vmId: string, seconds: number | null) => Effect.suspend(() => {
      if (fakeOptions.budgetFails && seconds !== 0) return Effect.fail(new Error("runtime limit: connection reset"));
      recorded.budgets.push(seconds);
      recorded.log.push(`budget:${seconds}`);
      return Effect.void;
    }),
    resume: (_provider: string, vmId: string) => Effect.sync(() => {
      recorded.resumed.push(vmId);
      recorded.log.push("resume");
      providerState.set(vmId, "running");
    }).pipe(Effect.andThen(runHook(fakeOptions.afterResume)), Effect.as({ id: vmId, status: "running" })),
  } as unknown as VmProviderGatewayShape;
  // main's access check (requireAccessibleUserVm) also reads the billing gateway.
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  /** A person's Pause Machine landing now, through pauseVm: whatever that path records is what the cron sees. */
  const userPause = (id: string): Effect.Effect<void> => Effect.suspend(() => {
    const row = rows.find((r) => r.id === id);
    if (!row?.providerVmId) return Effect.void;
    return pauseVm({ userId: row.userId, billingTeamId: row.billingTeamId, teamIds: [row.billingTeamId ?? ""], providerVmId: row.providerVmId }).pipe(
      Effect.provide(layer),
      Effect.asVoid,
      Effect.orDie,
    );
  });
  /** The status reconciler recording the provider's state: no reason, no intent. */
  const reconcilerSees = (id: string, status: "paused" | "running") => {
    const row = rows.find((r) => r.id === id);
    if (!row?.providerVmId) return;
    Effect.runSync(repo.markProviderObservedStatus({ id, providerVmId: row.providerVmId, status }));
  };
  /** A resume as reservePausedResume writes it: running again, observation dropped, fence and updatedAt moved. */
  const resume = (id: string, at: number) => update(id, (row) => ({
    ...row,
    status: "running",
    updatedAt: new Date(at),
    providerMetadata: bumped(row, withoutObservation(row.providerMetadata ?? {})),
  }));
  ctx.userPause = userPause;
  ctx.reconcilerSees = reconcilerSees;
  return { recorded, layer, resume, repo, provider, providerState, userPause, reconcilerSees };
}

function byId<T extends { readonly id: string }>(items: readonly T[]): T[] {
  return [...items].sort((a, b) => a.id.localeCompare(b.id));
}

const probeLine = (overrides: Record<string, unknown> = {}) => JSON.stringify({
  v: 1,
  daemon: { attached_clients: 0, live_agents: 0, last_user_input_at_ms: null, last_agent_action_at_ms: null },
  acpmux: { busy_sessions: 0, last_updated_at_ms: null },
  busy_terminals: 0,
  ssh_sessions: 0,
  inbound_connections: 0,
  cpu_busy_ms: CPU0,
  ...overrides,
});

describe("idle pause cron", () => {
  test("pauses an idle machine past its timeout through the pause path, with reason idle", async () => {
    const idle = machineRow({
      providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
    });
    const { recorded, layer } = cronFakes([idle], () => ({ exitCode: 0, stdout: probeLine() }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 1, errors: 0 });
    // The probe, then the re-probe inside the claim just before the provider pause.
    expect(recorded.execs).toHaveLength(2);
    expect(recorded.execs[0]).toMatchObject({ vmId: VM, asRoot: true });
    expect(recorded.execs[0].command).toContain("10.192.0.5");
    expect(recorded.paused).toEqual([VM]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused", pauseReason: "idle" }]);
    expect(recorded.events).toEqual([{ source: "idle", automated: true }]);
  });

  test("the probe's exec is cancelled at the provider when its budget runs out", async () => {
    // Effect.timeout only interrupts the fiber; the gateway aborts the provider request only with cancelOnInterrupt.
    const { recorded, layer } = cronFakes([machineRow()], () => ({ exitCode: 0, stdout: probeLine() }));
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(recorded.execs.length).toBeGreaterThan(0);
    expect(recorded.execs.map((e) => e.cancelOnInterrupt)).toEqual(recorded.execs.map(() => true));
  });

  test("a machine running an agent turn is not paused and its stretch is cleared", async () => {
    const busy = machineRow({
      providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 90 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
    });
    const { recorded, layer } = cronFakes([busy], () => ({ exitCode: 0, stdout: probeLine({ acpmux: { busy_sessions: 1, last_updated_at_ms: null } }) }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 0, active: 1 });
    expect(recorded.paused).toEqual([]);
    expect(recorded.observations).toEqual([{ id: "row-1", observation: null }]);
  });

  test("a failed or garbled probe is unknown and never pauses", async () => {
    const previous = { providerVmId: VM, idleSince: T0 - 90 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    for (const out of ["fails", { exitCode: 1, stdout: probeLine() }, { exitCode: 0, stdout: "python3: not found" }] as const) {
      const { recorded, layer } = cronFakes([machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: previous } })], () => out);
      const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
      expect(summary).toMatchObject({ checked: 1, paused: 0, unknown: 1, errors: 0 });
      expect(recorded.paused).toEqual([]);
    }
  });

  test("a machine set to Off is not probed and not paused; a first idle probe only starts the stretch", async () => {
    const off = machineRow({ id: "row-off", providerVmId: "fs-off", providerMetadata: { networkIpv4: "10.192.0.6", cmuxIdlePauseMinutes: 0 } });
    const fresh = machineRow({ id: "row-new", providerVmId: "fs-new", providerMetadata: { networkIpv4: "10.192.0.7" } });
    const { recorded, layer } = cronFakes([off, fresh], () => ({ exitCode: 0, stdout: probeLine() }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 2, paused: 0, off: 1, idle: 1 });
    expect(recorded.execs.map((e) => e.vmId)).toEqual(["fs-new"]);
    expect(byId(recorded.observations)).toEqual([
      { id: "row-new", observation: { providerVmId: "fs-new", idleSince: T0, observedAt: T0, cpuBusyMs: CPU0 } },
      { id: "row-off", observation: null },
    ]);
  });
});

describe("pause reason and the per-machine setting", () => {
  test("a person's pause records reason user", async () => {
    const { recorded, layer } = cronFakes([machineRow()], () => "fails");
    await Effect.runPromise(pauseVm({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: VM }).pipe(Effect.provide(layer)));
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused", pauseReason: "user" }]);
    expect(recorded.events).toEqual([{ source: "user" }]);
  });

  test("the reason shows only while paused; a stored observation belongs to its machine", () => {
    expect(vmPauseReasonFromRow({ status: "paused", providerMetadata: { cmuxPauseReason: "idle" } })).toBe("idle");
    expect(vmPauseReasonFromRow({ status: "paused", providerMetadata: { cmuxPauseReason: "user" } })).toBe("user");
    expect(vmPauseReasonFromRow({ status: "running", providerMetadata: { cmuxPauseReason: "idle" } })).toBeNull();
    expect(vmPauseReasonFromRow({ status: "paused", providerMetadata: {} })).toBeNull();
    const observation = { providerVmId: VM, idleSince: T0, observedAt: T0 + MIN, cpuBusyMs: CPU0 };
    expect(vmIdleObservationFromRow({ providerVmId: VM, providerMetadata: { cmuxIdleObservation: observation } })).toEqual(observation);
    expect(vmIdleObservationFromRow({ providerVmId: "fs-2", providerMetadata: { cmuxIdleObservation: observation } })).toBeNull();
  });

  test("setting the idle pause stores the choice and answers the machine with it", async () => {
    // Inside the free access window, so the access check needs no plan.
    const { recorded, layer } = cronFakes([machineRow({ createdAt: new Date() })], () => "fails");
    const entry = await Effect.runPromise(setVmIdlePause({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: VM, minutes: 120 }).pipe(Effect.provide(layer)));
    expect(recorded.minutes).toEqual([{ id: "row-1", minutes: 120 }]);
    expect(entry.idlePauseMinutes).toBe(120);
    expect(entry.pauseReason).toBeNull();
  });

  test("the route body takes off, 0, 15, 30, 60 or 120 and nothing else", async () => {
    expect(parseIdlePauseBody({ minutes: "off" })).toEqual({ ok: true, minutes: 0 });
    for (const minutes of [0, 15, 30, 60, 120]) expect(parseIdlePauseBody({ minutes })).toEqual({ ok: true, minutes });
    for (const body of [{ minutes: 45 }, { minutes: "30" }, {}, null, [30]]) {
      const parsed = parseIdlePauseBody(body);
      expect(parsed.ok).toBe(false);
      if (!parsed.ok) {
        expect(parsed.response.status).toBe(400);
        expect(await parsed.response.json()).toMatchObject({ error: "invalid_idle_pause" });
      }
    }
  });

  test("a create takes the same choices as idlePauseMinutes, and none keeps the default", async () => {
    expect(parseCreateIdlePause({})).toEqual({ ok: true, minutes: undefined });
    expect(parseCreateIdlePause({ idlePauseMinutes: "off" })).toEqual({ ok: true, minutes: 0 });
    for (const minutes of [0, 15, 30, 60, 120]) expect(parseCreateIdlePause({ idlePauseMinutes: minutes })).toEqual({ ok: true, minutes });
    for (const idlePauseMinutes of [45, "30", null, true, [0]]) {
      const parsed = parseCreateIdlePause({ idlePauseMinutes });
      expect(parsed.ok).toBe(false);
      if (!parsed.ok) {
        expect(parsed.response.status).toBe(400);
        expect(await parsed.response.json()).toMatchObject({ error: "invalid_idle_pause", details: { field: "idlePauseMinutes" } });
      }
    }
  });
});

describe("CPU work with no terminal", () => {
  /** A probe whose busy CPU counter grows at `cores` from a boot-time baseline. */
  const cpuProbe = (cores: number, base = 4_000_000) => (now: number) => idleProbe({ cpuBusyMs: Math.round(base + (now - T0) * cores) });

  test("CPU use between two idle probes is activity: a `nohup make` never pauses", () => {
    expect(VM_IDLE_CPU_BUSY_CORES).toBe(0.05);
    // One core busy the whole time, no terminal, no session: a build started with nohup.
    expect(runCron(cpuProbe(1), 6 * 60).pausedAfterMinutes).toBeNull();
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: 1_000 };
    const building = idleProbe({ cpuBusyMs: 1_000 + 5 * MIN });
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: building, previous, now: T0 }))
      .toEqual({ pause: false, reason: "active:cpu", observation: null });
    // Exactly at the threshold counts as busy.
    const atThreshold = idleProbe({ cpuBusyMs: 1_000 + 5 * MIN * VM_IDLE_CPU_BUSY_CORES });
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: atThreshold, previous, now: T0 }).reason).toBe("active:cpu");
  });

  test("an idle machine whose CPU stays under the threshold still pauses after the timeout", () => {
    expect(runCron(cpuProbe(0.01), 120).pausedAfterMinutes).toBe(30);
    expect(runCron(cpuProbe(0), 120).pausedAfterMinutes).toBe(30);
    // The stored observation keeps the last sample for the next run.
    const first = decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe({ cpuBusyMs: 1234 }), previous: null, now: T0 });
    expect(first.observation).toEqual({ providerVmId: VM, idleSince: T0, observedAt: T0, cpuBusyMs: 1234 });
  });

  test("a build in the middle of the stretch starts it over", () => {
    // Idle, a build between minutes 20 and 25, then idle: 30 minutes from the first idle probe after it.
    const counter = (now: number) => 4_000_000 + Math.min(Math.max(now - (T0 + 20 * MIN), 0), 5 * MIN);
    expect(runCron((now) => idleProbe({ cpuBusyMs: counter(now) }), 120).pausedAfterMinutes).toBe(60);
  });

  test("a counter that went back (a reboot) restarts the stretch", () => {
    const previous = { providerVmId: VM, idleSince: T0 - 40 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: 9_000_000 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe({ cpuBusyMs: 1_000 }), previous, now: T0 })).toEqual({
      pause: false, reason: "idle", observation: { providerVmId: VM, idleSince: T0, observedAt: T0, cpuBusyMs: 1_000 },
    });
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe({ cpuBusyMs: 9_000_100 }), previous, now: T0 }).pause).toBe(true);
  });

  test("a probe without a CPU sample is unknown; a stored observation without one does not carry the stretch", () => {
    const withCpu = { providerVmId: VM, idleSince: T0 - 30 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const withoutCpu = { providerVmId: VM, idleSince: T0 - 30 * MIN, observedAt: T0 - 5 * MIN };
    // Background work could be running and nothing measured it: never pause on that.
    for (const cpuBusyMs of [undefined, null]) {
      expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe({ cpuBusyMs }), previous: withCpu, now: T0 }))
        .toEqual({ pause: false, reason: "unknown:cpu", observation: null });
    }
    // Nothing measured the CPU between the stored observation and now: the stretch starts here.
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: withoutCpu, now: T0 })).toEqual({
      pause: false, reason: "idle", observation: { providerVmId: VM, idleSince: T0, observedAt: T0, cpuBusyMs: CPU0 },
    });
  });

  test("the cron never pauses a machine whose probe could not read the CPU", async () => {
    const row = machineRow({
      providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
    });
    const { recorded, layer } = cronFakes([row], () => ({ exitCode: 0, stdout: probeLine({ cpu_busy_ms: null }) }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 0, unknown: 1 });
    expect(recorded.paused).toEqual([]);
    expect(recorded.observations).toEqual([{ id: "row-1", observation: null }]);
  });

  test("the probe line's CPU field is optional; the stored sample is validated on its own", () => {
    const base = { v: 1, daemon: null, acpmux: null, busy_terminals: 0, ssh_sessions: 0, inbound_connections: 0 };
    expect(parseVmIdleProbe(JSON.stringify({ ...base, cpu_busy_ms: 12_700 }))?.cpuBusyMs).toBe(12_700);
    for (const cpu of [null, -1, "12", undefined]) {
      const parsed = parseVmIdleProbe(JSON.stringify({ ...base, cpu_busy_ms: cpu }));
      expect(parsed).not.toBeNull();
      expect(parsed?.cpuBusyMs).toBeUndefined();
    }
    const stored = { providerVmId: VM, idleSince: T0, observedAt: T0 + MIN };
    expect(vmIdleObservationFromRow({ providerVmId: VM, providerMetadata: { cmuxIdleObservation: { ...stored, cpuBusyMs: 5 } } }))
      .toEqual({ ...stored, cpuBusyMs: 5 });
    for (const cpuBusyMs of ["5", -5, null]) {
      expect(vmIdleObservationFromRow({ providerVmId: VM, providerMetadata: { cmuxIdleObservation: { ...stored, cpuBusyMs } } })).toEqual(stored);
    }
  });

  test("the guest script reports busy CPU time from /proc/stat, without idle, iowait or steal", async () => {
    const out = await runProbeScript({
      stat: "cpu  1000 50 200 90000 300 5 15 70 0 0\ncpu0 1000 50 200 90000 300 5 15 70 0 0\nintr 12345\n",
      "net/tcp": TCP_HEADER,
      "net/tcp6": TCP_HEADER,
    }, "NONE");
    // (user 1000 + nice 50 + system 200 + irq 5 + softirq 15) ticks at 100 Hz.
    expect(out.cpu_busy_ms).toBe(12_700);
    expect((await runProbeScript({ "net/tcp": TCP_HEADER, "net/tcp6": TCP_HEADER }, "NONE")).cpu_busy_ms).toBeNull();
    expect((await runProbeScript({ stat: "intr 1\n", "net/tcp": TCP_HEADER }, "NONE")).cpu_busy_ms).toBeNull();
  });
});

describe("API activity", () => {
  test("an exec, files or attach call within the timeout keeps the machine awake", () => {
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const decide = (lastApiActivityAt: number | null) =>
      decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous, now: T0, lastApiActivityAt });
    expect(decide(T0 - 10 * MIN)).toMatchObject({ pause: false, reason: "idle" });
    expect(decide(T0 - 29 * MIN).pause).toBe(false);
    expect(decide(T0 - 30 * MIN).pause).toBe(true);
    expect(decide(null).pause).toBe(true);
    expect(vmLastApiActivityFromRow({ providerMetadata: { cmuxLastApiActivityAt: T0 } })).toBe(T0);
    expect(vmLastApiActivityFromRow({ providerMetadata: { cmuxLastApiActivityAt: "soon" } })).toBeNull();
  });

  test("the cron counts the stored API activity time", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const row = machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: observation, cmuxLastApiActivityAt: T0 - 3 * MIN } });
    const { recorded, layer } = cronFakes([row], () => ({ exitCode: 0, stdout: probeLine() }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 0, idle: 1 });
    expect(recorded.paused).toEqual([]);
  });

  test("a person's exec records the time, once a minute; the idle cron's own probe does not", async () => {
    // Inside the free access window, so the access check needs no plan.
    const rows = [machineRow({ createdAt: new Date() })];
    const { recorded, layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: "ok" }));
    const exec = () => Effect.runPromise(execVm({
      userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: VM, command: "make", timeoutMs: 30_000,
    }).pipe(Effect.provide(layer)));
    const before = Date.now();
    expect((await exec()).exitCode).toBe(0);
    expect(recorded.apiActivity).toHaveLength(1);
    expect(recorded.apiActivity[0].at).toBeGreaterThanOrEqual(before);
    expect(vmLastApiActivityFromRow(rows[0])).toBe(recorded.apiActivity[0].at);
    // A second exec within the minute writes nothing.
    await exec();
    expect(recorded.apiActivity).toHaveLength(1);
    // The cron probes through the provider's exec as root and records no API activity.
    await Effect.runPromise(enforceVmIdlePause().pipe(Effect.provide(layer)));
    expect(recorded.execs.at(-1)).toMatchObject({ vmId: VM, asRoot: true });
    expect(recorded.apiActivity).toHaveLength(1);
  });
});

describe("resize activity fences", () => {
  test("a resize fences an overdue cron candidate before provider preflight", async () => {
    const now = Date.now();
    const candidate = machineRow({ createdAt: new Date(now), providerMetadata: {
      networkIpv4: "10.192.0.5",
      cmuxIdleObservation: { providerVmId: VM, idleSince: now - 31 * MIN, observedAt: now - 5 * MIN, cpuBusyMs: CPU0 },
    } });
    const rows = [candidate];
    const { repo, provider, recorded } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    // The cron selected this row before the resize began; its re-read sees live state.
    const cronLayer = Layer.mergeAll(
      Layer.succeed(VmRepository, { ...repo, idlePauseCandidates: () => Effect.succeed([candidate]) }),
      Layer.succeed(VmProviderGateway, provider),
    );
    let preflightChecks = 0;
    const resizeLayer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
      Layer.succeed(VmProviderGateway, {
        ...provider,
        getStatus: () => enforceVmIdlePause({ now: () => now }).pipe(
          Effect.provide(cronLayer),
          Effect.orDie,
          Effect.tap((summary) => Effect.sync(() => {
            preflightChecks += 1;
            expect(summary).toMatchObject({ paused: 0, claim_refused: 1 });
          })),
          Effect.as("running" as const),
        ),
        getStats: () => Effect.succeed({ state: "awake" as const, sampledAt: Date.now(), cpus: 2, memoryTotalMb: 4096, diskTotalMb: 32768 }),
        resize: () => Effect.void,
      }),
    );
    await Effect.runPromise(resizeVm({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"],
      providerVmId: VM, cpu: 2 }).pipe(Effect.provide(resizeLayer)));
    expect(preflightChecks).toBe(1);
    expect(recorded.paused).toEqual([]);
    expect(recorded.apiActivity).toHaveLength(1);
    expect(vmLastApiActivityFromRow(rows[0])).toBeGreaterThanOrEqual(now);
  });

  test("a resize stops before provider work when its activity write fails", async () => {
    const { repo, provider } = cronFakes([machineRow({ createdAt: new Date() })], () => "fails");
    let providerCalls = 0;
    const failure = new VmDatabaseError({ operation: "recordVmApiActivity", cause: new Error("unavailable") });
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, { ...repo, recordVmApiActivity: () => Effect.fail(failure) }),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
      Layer.succeed(VmProviderGateway, {
        ...provider,
        getStatus: () => Effect.sync(() => { providerCalls += 1; return "running" as const; }),
        getStats: () => Effect.sync(() => { providerCalls += 1; return { state: "awake" as const, sampledAt: Date.now(), cpus: 2, memoryTotalMb: 4096 }; }),
        resize: () => Effect.sync(() => { providerCalls += 1; }),
      }),
    );
    const result = await Effect.runPromise(resizeVm({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"],
      providerVmId: VM, cpu: 2 }).pipe(Effect.provide(layer), Effect.either));
    expect(result).toMatchObject({ _tag: "Left", left: failure });
    expect(providerCalls).toBe(0);
  });
});

describe("no private address", () => {
  test("a row without a private address is unknown: not probed, never paused, observation cleared", async () => {
    const fresh = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: fresh, now: T0, privateAddressKnown: false }))
      .toEqual({ pause: false, reason: "unknown:address", observation: null });
    // Off stays Off.
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 0, probe: null, previous: null, now: T0, privateAddressKnown: false }).reason).toBe("off");
    const row = machineRow({ providerMetadata: { networkIpv4: "", cmuxIdleObservation: fresh } });
    const { recorded, layer } = cronFakes([row], () => ({ exitCode: 0, stdout: probeLine() }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 0, unknown: 1 });
    expect(recorded.execs).toEqual([]);
    expect(recorded.paused).toEqual([]);
    expect(recorded.observations).toEqual([{ id: "row-1", observation: null }]);
  });
});

describe("malformed private VPC metadata", () => {
  test("one bad address cannot hide inbound connections on the other interface", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    for (const providerMetadata of [
      { networkIpv4: "10.192.0.999" },
      { networkIpv4: "10.192.0.5", networkIpv6: "fd00::ggg" },
      { networkIpv4: "10.192.0.5", networkIpv6: 1234 },
    ]) {
      const row = machineRow({ providerMetadata: { ...providerMetadata, cmuxIdleObservation: observation } });
      expect(vmIdlePrivateAddressesFromRow(row)).toEqual([]);
      const { recorded, layer } = cronFakes([row], () => ({ exitCode: 0, stdout: probeLine() }));
      const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
      expect(summary).toMatchObject({ checked: 1, paused: 0, unknown: 1 });
      expect(recorded.execs).toEqual([]);
      expect(recorded.paused).toEqual([]);
      expect(recorded.observations).toEqual([{ id: "row-1", observation: null }]);
    }
    expect(vmIdlePrivateAddressesFromRow({ providerMetadata: { networkIpv4: "10.192.0.5", networkIpv6: "fd00:7::5" } }))
      .toEqual(["10.192.0.5", "fd00:7::5"]);
  });
});

describe("pause, resume and the idle stretch", () => {
  test("an observation from before a pause would carry; cleared, the stretch restarts", () => {
    const beforePause = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    // What clearing prevents: resumed and probed within the gap, the old stretch would pause at once.
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: beforePause, now: T0 + 5 * MIN }).pause).toBe(true);
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: null, now: T0 + 5 * MIN })).toEqual({
      pause: false, reason: "idle", observation: { providerVmId: VM, idleSince: T0 + 5 * MIN, observedAt: T0 + 5 * MIN, cpuBusyMs: CPU0 },
    });
  });

  test("pause, resume, then an idle probe: not paused again until a full timeout after the resume", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const rows = [machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: observation } })];
    const { recorded, layer, resume } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    const runAt = (now: number) => Effect.runPromise(enforceVmIdlePause({ now: () => now }).pipe(Effect.provide(layer)));
    expect(await runAt(T0)).toMatchObject({ paused: 1 });
    expect(rows[0].status).toBe("paused");
    expect(omit(omit(omit(omit(rows[0].providerMetadata, "cmuxIdleEpoch"), "cmuxPauseIntentEpoch"), "cmuxIdleLastDecision"), "cmuxIdleProbedAt")).toEqual({ networkIpv4: "10.192.0.5", cmuxPauseReason: "idle" });
    // Opened a minute later; the next runs see an idle machine.
    resume("row-1", T0 + MIN);
    expect(await runAt(T0 + 5 * MIN)).toMatchObject({ paused: 0, idle: 1 });
    expect(rows[0].providerMetadata.cmuxIdleObservation).toEqual({ providerVmId: VM, idleSince: T0 + 5 * MIN, observedAt: T0 + 5 * MIN, cpuBusyMs: CPU0 });
    for (let t = 10; t < 35; t += 5) expect(await runAt(T0 + t * MIN)).toMatchObject({ paused: 0, idle: 1 });
    expect(await runAt(T0 + 35 * MIN)).toMatchObject({ paused: 1 });
    expect(recorded.paused).toEqual([VM, VM]);
  });

  test("every checked machine records when it was checked, so capped runs rotate", async () => {
    const off = machineRow({ id: "row-off", providerVmId: "fs-off", providerMetadata: { networkIpv4: "10.192.0.6", cmuxIdlePauseMinutes: 0 } });
    const unknown = machineRow({ id: "row-unknown", providerVmId: "fs-unknown", providerMetadata: {} });
    const idle = machineRow({ id: "row-idle", providerVmId: "fs-idle" });
    const rows = [off, unknown, idle];
    const { recorded, layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(byId(recorded.probedAt)).toEqual([
      { id: "row-idle", probedAt: T0 },
      { id: "row-off", probedAt: T0 },
      { id: "row-unknown", probedAt: T0 },
    ]);
    for (const row of rows) expect(row.providerMetadata.cmuxIdleProbedAt).toBe(T0);
  });

  test("a pause is skipped when the row moved since the candidate read", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const rereads: Array<(row: CloudVmRow) => CloudVmRow | null> = [
      // An exec landed.
      (row) => ({ ...row, providerMetadata: { ...row.providerMetadata, cmuxLastApiActivityAt: T0 } }),
      // Paused or replaced meanwhile.
      (row) => ({ ...row, status: "paused" }),
      (row) => ({ ...row, providerVmId: "fs-replaced" }),
      () => null,
    ];
    for (const reread of rereads) {
      const row = machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: observation } });
      const { recorded, layer } = cronFakes([row], () => ({ exitCode: 0, stdout: probeLine() }), { reread });
      const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
      expect(summary).toMatchObject({ checked: 1, paused: 0, claim_refused: 1, errors: 0 });
      expect(recorded.paused).toEqual([]);
      expect(recorded.observations).toEqual([]);
    }
  });

  test("an updatedAt-only write does not block an otherwise fenced idle pause", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const row = machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: observation } });
    const rows = [row];
    const { recorded, layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      // A display rename, resource retry, or provider metadata merge can move
      // updatedAt without changing the idle fence or the probe's address.
      reread: (current) => ({ ...current, updatedAt: new Date(current.updatedAt.getTime() + 1) }),
    });
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 1, active: 0 });
    expect(recorded.paused).toEqual([VM]);
  });

  test("a changed probe address refuses the claim without clearing the idle stretch", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const row = machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: observation } });
    const rows = [row];
    const { recorded, layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      reread: (current) => ({
        ...current,
        updatedAt: new Date(current.updatedAt.getTime() + 1),
        providerMetadata: { ...current.providerMetadata, networkIpv4: "10.192.0.6" },
      }),
    });
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 0, claim_refused: 1 });
    expect(recorded.paused).toEqual([]);
    expect(rows[0].providerMetadata?.cmuxIdleObservation).toEqual(observation);
    expect(epochOf(rows[0])).toBe(epochOf(row));
    expect(recorded.observations).toEqual([]);
    expect(rows[0].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ outcome: "claim_refused", reason: "private_address_changed" });
  });
});

describe("overlapping probes", () => {
  // Run A reads the row, then probes for up to a minute. Anything that lands
  // meanwhile moved the row's fence, so A's observation is stale and must not
  // be stored: it would bring back an idle stretch the newer write ended.
  const carried = { providerVmId: VM, idleSince: T0 - 20 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
  const stale = () => machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: carried } });

  test("another run's newer write wins over this run's stale observation", async () => {
    const rows = [stale()];
    const { layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      // Run B saw the machine busy and cleared the stretch while A was probing.
      duringProbe: (repo) => Effect.runSync(repo.recordIdleObservation!({
        id: "row-1", providerVmId: VM, observation: null, probedAt: T0, epoch: epochOf(rows[0]),
      } as Parameters<NonNullable<VmRepositoryShape["recordIdleObservation"]>>[0])),
    });
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(rows[0].providerMetadata.cmuxIdleObservation).toBeUndefined();
  });

  test("a probe that straddles a pause and a resume cannot restore the old idleSince", async () => {
    const rows = [stale()];
    const { layer, resume } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      duringProbe: (repo) => {
        Effect.runSync(repo.markProviderObservedStatus({ id: "row-1", providerVmId: VM, status: "paused", pauseReason: "user" }));
        resume("row-1", T0);
      },
    });
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdleObservation).toBeUndefined();
  });

  test("API activity during the probe also fences the observation out", async () => {
    const rows = [stale()];
    const { layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      // At the throttle's edge the activity write lands but is older than the timeout window cares about.
      duringProbe: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 - 40 * MIN })),
    });
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    // A's write lost: the row keeps what it had, not A's re-stamped stretch.
    expect(rows[0].providerMetadata.cmuxIdleObservation).toEqual(carried);
    expect(rows[0].providerMetadata.cmuxIdleProbedAt).toBe(T0); // Diagnostics advance scheduling, not the idle observation.
  });
});

describe("writes that land while the provider pauses", () => {
  // The provider pause takes seconds. A person's exec, a switch to Off, or a
  // person's own pause can land in between; the cron's pause record is fenced
  // on the epoch it claimed, so it loses and the cron undoes or keeps what the
  // newer write meant. No budget plan, so the resume needs no billing read.
  const overdue = () => machineRow({
    billingPlanId: null,
    providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
  });
  const runWith = async (duringPause: (repo: VmRepositoryShape) => void) => {
    const rows = [overdue()];
    const fakes = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), { duringPause });
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(fakes.layer)));
    return { rows, summary, ...fakes };
  };

  test("an exec during the pause: no idle pause is recorded and the machine is resumed", async () => {
    const { rows, summary, recorded } = await runWith((repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })));
    expect(summary).toMatchObject({ checked: 1, paused: 0, aborted: 1, errors: 0 });
    expect(recorded.paused).toEqual([VM]);
    expect(recorded.statuses.filter((s) => s.status === "paused")).toEqual([]);
    expect(recorded.events).not.toContainEqual({ source: "idle", automated: true });
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBeUndefined();
  });

  test("Off chosen during the pause: no idle pause is recorded and the machine is resumed", async () => {
    const { rows, summary, recorded } = await runWith((repo) => Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 })));
    expect(summary).toMatchObject({ checked: 1, paused: 0, aborted: 1, errors: 0 });
    expect(recorded.statuses.filter((s) => s.status === "paused")).toEqual([]);
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseMinutes).toBe(0);
  });

  test("a person's pause that recorded first is kept as theirs, not resumed", async () => {
    const { rows, summary, recorded } = await runWith((repo) => Effect.runSync(repo.markProviderObservedStatus({ id: "row-1", providerVmId: VM, status: "paused", pauseReason: "user" })));
    expect(summary).toMatchObject({ checked: 1, paused: 0, aborted: 1, errors: 0 });
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused", pauseReason: "user" }]);
    expect(recorded.resumed).toEqual([]);
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
  });

  test("nothing lands: the pause records as before", async () => {
    const { rows, summary, recorded } = await runWith(() => {});
    expect(summary).toMatchObject({ checked: 1, paused: 1, aborted: 0, errors: 0 });
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused", pauseReason: "idle" }]);
    expect(recorded.resumed).toEqual([]);
    expect(rows[0].status).toBe("paused");
  });
});

describe("the pause's other races", () => {
  const overdue = () => machineRow({
    billingPlanId: null,
    providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
  });
  type Options = NonNullable<Parameters<typeof cronFakes>[2]>;
  const setup = (options: Options, probeOut: Parameters<typeof cronFakes>[1] = () => ({ exitCode: 0, stdout: probeLine() })) => {
    const rows = [overdue()];
    const fakes = cronFakes(rows, probeOut, options);
    const runAt = (now: number) => Effect.runPromise(enforceVmIdlePause({ now: () => now }).pipe(Effect.provide(fakes.layer)));
    return { rows, runAt, ...fakes };
  };

  test("activity lands, then the status reconciler records the provider's pause: still resumed", async () => {
    // The reconciler's paused write carries no intent, so it is not a person's pause.
    const { rows, runAt, recorded, providerState } = setup({
      duringPause: (repo, ctx) => {
        Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 }));
        ctx.reconcilerSees("row-1", "paused");
      },
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1, errors: 0 });
    expect(recorded.resumed).toEqual([VM]);
    expect(providerState.get(VM)).toBe("running");
    expect(rows[0].status).toBe("running");
  });

  test("a person's pause recorded before the claim is not theirs to keep after Off moved past it", async () => {
    // Only a person's pause newer than the cron's claim wins; this one is older (a stale reason on a row the cron claimed).
    const { rows, runAt, recorded } = setup({
      duringPause: (repo, ctx) => {
        Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 }));
        ctx.reconcilerSees("row-1", "paused");
      },
    });
    rows[0] = { ...rows[0], providerMetadata: { ...rows[0].providerMetadata, cmuxPauseReason: "user", cmuxPauseIntentEpoch: 0 } };
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
  });

  test("the provider accepts the pause but its answer is lost, and Off landed: read back, resumed", async () => {
    const { rows, runAt, recorded, providerState } = setup({
      pauseFails: "accepted",
      duringPause: (repo) => Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 })),
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.resumed).toEqual([VM]);
    expect(providerState.get(VM)).toBe("running");
    expect(rows[0].status).toBe("running");
  });

  test("the provider accepts the pause but its answer is lost, nothing landed: the pause is recorded", async () => {
    const { rows, runAt, recorded } = setup({ pauseFails: "accepted" });
    expect(await runAt(T0)).toMatchObject({ paused: 1, errors: 0 });
    expect(rows[0]).toMatchObject({ status: "paused" });
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("idle");
    expect(recorded.events).toEqual([{ source: "idle", automated: true }]);
  });

  test("a lost answer the cron cannot read back leaves its claim; the next run reconciles it", async () => {
    // The pause went through, then the read-back failed too.
    const { rows, runAt, recorded, providerState } = setup({ pauseFails: "accepted", statusFailures: 1 });
    expect(await runAt(T0)).toMatchObject({ paused: 0, errors: 1 });
    expect(providerState.get(VM)).toBe("paused");
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBe(epochOf(rows[0]));
    // Next run: nothing moved the fence since the claim, so the provider's pause is recorded as the idle pause.
    expect(await runAt(T0 + 5 * MIN)).toMatchObject({ paused: 1, errors: 0 });
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("idle");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(recorded.resumed).toEqual([]);
  });

  test("a left claim whose fence moved since (an exec): the next run resumes the machine", async () => {
    const { rows, runAt, recorded, repo } = setup({ pauseFails: "accepted", statusFailures: 1 });
    expect(await runAt(T0)).toMatchObject({ errors: 1 });
    Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 + MIN }));
    expect(await runAt(T0 + 5 * MIN)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
  });

  test("a refused pause leaves the machine running; the next run finds it running and clears the claim", async () => {
    const { rows, runAt, recorded, providerState } = setup({ pauseFails: "refused" });
    expect(await runAt(T0)).toMatchObject({ paused: 0, errors: 1 });
    expect(providerState.get(VM) ?? "running").toBe("running");
    expect(rows[0].status).toBe("running");
    await runAt(T0 + 5 * MIN);
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(recorded.resumed).toEqual([]);
  });

  test("guest activity between the probe and the pause: the re-probe sees it and nothing pauses", async () => {
    const busy = probeLine({ busy_terminals: 1 });
    const { rows, runAt, recorded } = setup({}, (_vmId, call) => ({ exitCode: 0, stdout: call === 0 ? probeLine() : busy }));
    expect(await runAt(T0)).toMatchObject({ paused: 0, active: 1, errors: 0 });
    expect(recorded.execs).toHaveLength(2);
    expect(recorded.paused).toEqual([]);
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdleObservation).toBeUndefined();
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
  });

  test("a re-probe that fails is unknown and nothing pauses", async () => {
    const { runAt, recorded } = setup({}, (_vmId, call) => (call === 0 ? { exitCode: 0, stdout: probeLine() } : "fails"));
    expect(await runAt(T0)).toMatchObject({ paused: 0, unknown: 1, errors: 0 });
    expect(recorded.paused).toEqual([]);
  });

  test("a person's pause after the compensation read, before its claim: theirs wins, no resume", async () => {
    let paused = false;
    const { rows, runAt, recorded, providerState } = setup({
      duringPause: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
      beforeResumeClaim: (_repo, ctx) => {
        if (paused) return;
        paused = true;
        return ctx.userPause("row-1");
      },
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.resumed).toEqual([]);
    expect(providerState.get(VM)).toBe("paused");
    expect(rows[0]).toMatchObject({ status: "paused" });
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
  });

  test("a person's pause after the compensation claim, before the provider resume: re-paused, theirs wins", async () => {
    let compensating = false;
    let paused = false;
    const { rows, runAt, providerState } = setup({
      duringPause: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
      beforeResumeClaim: () => { compensating = true; },
      duringStatus: (_repo, ctx) => {
        if (!compensating || paused) return;
        paused = true;
        return ctx.userPause("row-1");
      },
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(providerState.get(VM)).toBe("paused");
    expect(rows[0]).toMatchObject({ status: "paused" });
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
  });

  test("accepted, fence moved, answer and read-back lost, then the reconciler records paused: the next run still resumes", async () => {
    const { rows, runAt, recorded, providerState, reconcilerSees } = setup({
      pauseFails: "accepted",
      statusFailures: 1,
      duringPause: (repo) => Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 })),
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, errors: 1 });
    // The status reconciler sees the provider's pause; its write states no intent, so the claim stays.
    reconcilerSees("row-1", "paused");
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    // The next run picks the paused row up by its claim and undoes the pause Off overtook.
    expect(await runAt(T0 + 5 * MIN)).toMatchObject({ checked: 1, aborted: 1 });
    expect(recorded.resumed).toEqual([VM]);
    expect(providerState.get(VM)).toBe("running");
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
  });

  test("the compensating resume loses its claim to Off and the reconciler: it keeps the pause claim and the next run resumes", async () => {
    let once = false;
    const { rows, runAt, recorded } = setup({
      duringPause: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
      beforeResumeClaim: (repo, ctx) => {
        if (once) return;
        once = true;
        Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 }));
        ctx.reconcilerSees("row-1", "paused");
      },
    });
    await runAt(T0);
    expect(recorded.resumed).toEqual([]);
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    expect(await runAt(T0 + 5 * MIN)).toMatchObject({ aborted: 1 });
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
  });

  test("the compensating resume wakes the machine but its running write loses to Off: the next run repairs the row", async () => {
    let once = false;
    const { rows, runAt, recorded, providerState } = setup({
      // Activity moves the fence and the reconciler records the provider's pause, so the row is paused.
      duringPause: (repo, ctx) => {
        Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 }));
        ctx.reconcilerSees("row-1", "paused");
      },
      afterResume: (repo) => {
        if (once) return;
        once = true;
        Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 }));
      },
    });
    await runAt(T0);
    expect(recorded.resumed).toEqual([VM]);
    expect(providerState.get(VM)).toBe("running");
    // The row still says paused and holds the claim: the fenced running write lost to Off.
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    // The next run finds the provider running and repairs the row through a fenced running write.
    await runAt(T0 + 5 * MIN);
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(recorded.resumed).toEqual([VM]);
  });

  test("a person's Pause after the repair's claim, before its running write: the provider is paused again", async () => {
    const claimed = machineRow({ billingPlanId: null, status: "paused", providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleEpoch: 4, cmuxIdlePauseClaim: 3 } });
    const rows = [claimed];
    const fakes = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      afterResumeClaim: (_repo, ctx) => ctx.userPause("row-1"),
    });
    fakes.providerState.set(VM, "running");
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(fakes.layer)));
    expect(summary).toMatchObject({ paused: 0, errors: 0 });
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(fakes.recorded.paused).toEqual([VM]);
    expect(fakes.providerState.get(VM)).toBe("paused");
  });

  /** The allowance enforcer's pause (goPause.ts): Plus through pauseGoVm, Pro and Max through pauseBudgetVm. */
  const allowancePause = (plan: "go" | "pro") => (repo: VmRepositoryShape) => Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const row = (yield* repo.findUserVm({ userId: "user-1", billingTeamId: "team-1", providerVmId: VM, provider: "freestyle" }))!;
    yield* plan === "go" ? pauseGoVm(repo, providers, row, VM, 0) : pauseBudgetVm(repo, providers, row, VM, 0);
  });

  for (const plan of ["go", "pro"] as const) {
    test(`an allowance pause (${plan}) after a claim the cron left: a later run does not resume it`, async () => {
      const rows = [machineRow({ billingPlanId: plan, providerMetadata: overdue().providerMetadata })];
      const fakes = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), { pauseFails: "refused" });
      const runAt = (now: number) => Effect.runPromise(enforceVmIdlePause({ now: () => now }).pipe(Effect.provide(fakes.layer)));
      await runAt(T0);
      expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
      // The allowance runs out before the next cron run.
      await Effect.runPromise(allowancePause(plan)(fakes.repo).pipe(Effect.provide(fakes.layer)));
      expect(rows[0].status).toBe("paused");
      await runAt(T0 + 5 * MIN);
      expect(fakes.recorded.resumed).toEqual([]);
      expect(fakes.providerState.get(VM)).toBe("paused");
      expect(rows[0].status).toBe("paused");
      expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    });

    test(`an allowance pause (${plan}) while the cron's provider pause is under way: kept, not resumed`, async () => {
      const rows = [machineRow({ billingPlanId: plan, providerMetadata: overdue().providerMetadata })];
      const fakes = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), { duringPause: allowancePause(plan) });
      const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(fakes.layer)));
      expect(summary).toMatchObject({ paused: 0, aborted: 1, errors: 0 });
      expect(fakes.recorded.resumed).toEqual([]);
      expect(rows[0].status).toBe("paused");
      expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    });
  }

  test("a person's Pause on a row the reconciler already marked paused is still theirs: not undone", async () => {
    // Off moves the fence, the reconciler records the provider's pause, then the person presses Pause:
    // pauseVm's already-paused path must still record their decision.
    const { rows, runAt, recorded } = setup({
      duringPause: (repo, ctx) => {
        Effect.runSync(repo.setIdlePauseMinutes!({ id: "row-1", minutes: 0 }));
        ctx.reconcilerSees("row-1", "paused");
        return ctx.userPause("row-1");
      },
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.resumed).toEqual([]);
    expect(rows[0]).toMatchObject({ status: "paused" });
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
  });
});

describe("a Go machine's runtime budget after an idle pause recovery", () => {
  // The idle pause caps a Plus (go) machine's provider runtime at zero before pausing. Freestyle keeps an
  // exhausted limit and disables automatic restart, and Plus has no hour cap, so any recovery that leaves
  // the machine running clears the cap (null) before it settles the claim.
  const goRow = (overrides: Partial<CloudVmRow> = {}) => machineRow({
    billingPlanId: "go",
    providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
    ...overrides,
  });
  type Options = NonNullable<Parameters<typeof cronFakes>[2]>;
  const setup = (options: Options, row: CloudVmRow = goRow()) => {
    const rows = [row];
    const fakes = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), options);
    const runAt = (now: number) => Effect.runPromise(enforceVmIdlePause({ now: () => now }).pipe(Effect.provide(fakes.layer)));
    return { rows, runAt, ...fakes };
  };
  const restoredBefore = (log: readonly string[], write: string) => {
    const restored = log.lastIndexOf("budget:null");
    return restored >= 0 && restored < log.lastIndexOf(write);
  };

  test("a lost pause the compensation resumes gets its budget back before the resume", async () => {
    const { rows, runAt, recorded } = setup({
      duringPause: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.log).toEqual(["budget:0", "budget:null", "resume", "status:running"]);
    expect(rows[0].status).toBe("running");
  });

  test("the compensation finds the machine already running: the budget comes back before the running write", async () => {
    const { rows, runAt, recorded } = setup({
      duringPause: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
      // Something woke the machine after the pause and before the compensation reads it.
      beforeResumeClaim: (_repo, ctx) => {
        ctx.providerState.set(VM, "running");
      },
    });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1 });
    expect(recorded.resumed).toEqual([]);
    expect(recorded.budgets).toEqual([0, null]);
    expect(restoredBefore(recorded.log, "status:running")).toBe(true);
    expect(rows[0].status).toBe("running");
  });

  /** A person's Pause started now and held at its provider pause (intent written, cap zero set); release() lets it finish. */
  const heldUserPause = (ctx: { userPause: (id: string) => Effect.Effect<void> }, hold: { armed: boolean; reached: Deferred.Deferred<void>; release: Deferred.Deferred<void> }) =>
    Effect.gen(function* () {
      hold.armed = true;
      const fiber = yield* Effect.forkDaemon(ctx.userPause("row-1"));
      yield* Deferred.await(hold.reached);
      return fiber;
    });
  const newHold = () => ({ armed: false, reached: Effect.runSync(Deferred.make<void>()), release: Effect.runSync(Deferred.make<void>()) });
  const holdOnce = (hold: ReturnType<typeof newHold>) => () => {
    if (!hold.armed) return undefined;
    hold.armed = false;
    return Deferred.succeed(hold.reached, undefined).pipe(Effect.andThen(Deferred.await(hold.release)));
  };

  test("a person's Pause in flight before the next run reads its candidates: the left claim waits, the zero cap stays", async () => {
    const hold = newHold();
    const fakes = setup({ pauseFails: "refused", holdPause: holdOnce(hold) });
    const { rows, runAt, recorded, providerState } = fakes;
    await runAt(T0);
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    const fiber = await Effect.runPromise(heldUserPause(fakes, hold));
    expect(rows[0].providerMetadata.cmuxPendingPause).toBeDefined();
    await runAt(T0 + 5 * MIN);
    await Effect.runPromise(Deferred.succeed(hold.release, undefined).pipe(Effect.andThen(Fiber.join(fiber))));
    expect(rows[0]).toMatchObject({ status: "paused" });
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
    expect(providerState.get(VM)).toBe("paused");
    expect(recorded.budgets.at(-1)).toBe(0);
    expect(recorded.resumed).toEqual([]);
  });

  test("an idle claim is never taken over a person's Pause in flight", async () => {
    const hold = newHold();
    // The person's provider pause is the first one, so the first-pause hook holds it.
    const fakes = setup({ duringPause: holdOnce(hold) });
    const { rows, runAt, recorded } = fakes;
    const fiber = await Effect.runPromise(heldUserPause(fakes, hold));
    expect(await runAt(T0)).toMatchObject({ paused: 0 });
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(recorded.paused).toEqual([VM]);
    await Effect.runPromise(Deferred.succeed(hold.release, undefined).pipe(Effect.andThen(Fiber.join(fiber))));
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
    expect(recorded.budgets.at(-1)).toBe(0);
    expect(recorded.resumed).toEqual([]);
  });

  test("a left claim newer than a pending pause, fence moved (Off): the compensation leaves the pause and its cap alone", async () => {
    const pending = { cause: "user", epoch: 2, requestedAt: Date.now() - MIN };
    const row = goRow({ status: "paused", providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleEpoch: 5, cmuxIdlePauseClaim: 3, cmuxPendingPause: pending } });
    const { rows, runAt, recorded, providerState } = setup({}, row);
    providerState.set(VM, "paused");
    await runAt(T0);
    expect(recorded.resumed).toEqual([]);
    expect(recorded.budgets).toEqual([]);
    expect(providerState.get(VM)).toBe("paused");
    expect(rows[0].status).toBe("paused");
  });

  test("an abandoned pending pause (older than the intent's lifetime) no longer holds the recovery back", async () => {
    const pending = { cause: "user", epoch: 2, requestedAt: Date.now() - 2 * 60 * MIN };
    const row = goRow({ status: "paused", providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleEpoch: 5, cmuxIdlePauseClaim: 3, cmuxPendingPause: pending } });
    const { rows, runAt, recorded, providerState } = setup({}, row);
    providerState.set(VM, "paused");
    await runAt(T0);
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
  });

  test("a person's Pause in flight (cap zero, provider pause not back) during the left-claim recovery keeps its zero cap", async () => {
    let armed = false;
    let inFlight: Fiber.RuntimeFiber<void> | null = null;
    const reached = Effect.runSync(Deferred.make<void>());
    const release = Effect.runSync(Deferred.make<void>());
    const { rows, runAt, recorded, providerState } = setup({
      pauseFails: "refused",
      // The person's provider pause signals it got there, then waits until the cron run is over.
      holdPause: () => (armed || inFlight ? Deferred.succeed(reached, undefined).pipe(Effect.andThen(Deferred.await(release))) : undefined),
      // Next run: after the recovery reads the provider as running, the person's Pause starts and
      // gets as far as its provider pause (cap zero set) before the recovery goes on.
      afterStatus: (_repo, ctx) => {
        if (!armed) return;
        armed = false;
        return Effect.gen(function* () {
          inFlight = yield* Effect.forkDaemon(ctx.userPause("row-1"));
          yield* Deferred.await(reached);
        });
      },
    });
    await runAt(T0);
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    armed = true;
    await runAt(T0 + 5 * MIN);
    expect(inFlight).not.toBeNull();
    await Effect.runPromise(Deferred.succeed(release, undefined).pipe(Effect.andThen(Fiber.join(inFlight!))));
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
    expect(providerState.get(VM)).toBe("paused");
    // The person's zero cap is the last cap write: the recovery never cleared it under their pause.
    expect(recorded.budgets.at(-1)).toBe(0);
    expect(recorded.resumed).toEqual([]);
  });

  test("a person's Pause after the left claim's provider read: their zero cap stays and the machine stays paused", async () => {
    let armed = false;
    const { rows, runAt, recorded, providerState } = setup({
      pauseFails: "refused",
      // Next run: the recovery reads the provider as running, then the person's Pause lands
      // (cap zero, provider paused, claim settled) before it acts on that read.
      afterStatus: (_repo, ctx) => {
        if (!armed) return;
        armed = false;
        return ctx.userPause("row-1");
      },
    });
    await runAt(T0);
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    armed = true;
    await runAt(T0 + 5 * MIN);
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
    expect(providerState.get(VM)).toBe("paused");
    // The person's pause set the cap to zero last; nothing cleared it after.
    expect(recorded.budgets.at(-1)).toBe(0);
    expect(recorded.resumed).toEqual([]);
  });

  test("a person's Pause after the left claim's fence and cap clear: their pause and zero cap are put back", async () => {
    let armed = false;
    const { rows, runAt, recorded, providerState } = setup({
      pauseFails: "refused",
      afterResumeClaim: (_repo, ctx) => {
        if (!armed) return;
        armed = false;
        return ctx.userPause("row-1");
      },
    });
    await runAt(T0);
    armed = true;
    await runAt(T0 + 5 * MIN);
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata.cmuxPauseReason).toBe("user");
    expect(providerState.get(VM)).toBe("paused");
    expect(recorded.budgets.at(-1)).toBe(0);
    expect(recorded.resumed).toEqual([]);
  });

  test("a refused pause zeroed the budget: the next run gives it back before clearing the claim", async () => {
    const { rows, runAt, recorded } = setup({ pauseFails: "refused" });
    expect(await runAt(T0)).toMatchObject({ paused: 0, errors: 1 });
    expect(recorded.budgets).toEqual([0]);
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeDefined();
    await runAt(T0 + 5 * MIN);
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(recorded.budgets).toEqual([0, null]);
    expect(restoredBefore(recorded.log, "observation")).toBe(true);
  });

  test("a claimed paused row on a running machine: the repair gives the budget back before the running write", async () => {
    const claimed = goRow({ status: "paused", providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleEpoch: 4, cmuxIdlePauseClaim: 3 } });
    const { rows, runAt, recorded } = setup({}, claimed);
    expect(await runAt(T0)).toMatchObject({ paused: 0, errors: 0 });
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
    expect(recorded.resumed).toEqual([]);
    expect(recorded.budgets).toEqual([null]);
    expect(restoredBefore(recorded.log, "status:running")).toBe(true);
  });

  const activityDuringPause: Options = {
    duringPause: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
  };

  test("the cap write fails: the compensation still resumes and settles, and logs it", async () => {
    const { rows, runAt, recorded } = setup({ ...activityDuringPause, budgetFails: true });
    expect(await runAt(T0)).toMatchObject({ paused: 0, aborted: 1, errors: 0 });
    expect(recorded.resumed).toEqual([VM]);
    expect(rows[0].status).toBe("running");
    expect(rows[0].providerMetadata.cmuxIdlePauseClaim).toBeUndefined();
  });
});

const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;

describe("idle pause SQL", () => {
  const owner = `idle-test-${randomUUID()}`;
  const rowId = randomUUID();
  const otherId = randomUUID();
  const fenceId = randomUUID();
  const intentId = randomUUID();
  const keptId = randomUUID();
  const providerVmId = `fs-idle-${rowId}`;
  const fenceVmId = `fs-idle-${fenceId}`;
  let sql: Sql;

  beforeAll(async () => {
    if (!dbEnabled) return;
    sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 2 });
    await sql`insert into cloud_vms (id, user_id, billing_team_id, provider, provider_vm_id, image_id, status, provider_metadata)
      values (${rowId}, ${owner}, ${owner}, 'freestyle', ${providerVmId}, 'sh-test', 'running', '{"networkIpv4":"10.192.0.5"}'::jsonb),
             (${otherId}, ${owner}, ${owner}, 'freestyle', ${`fs-idle-${otherId}`}, 'sh-test', 'running', '{"cmuxIdleProbedAt":"junk"}'::jsonb),
             (${fenceId}, ${owner}, ${owner}, 'freestyle', ${fenceVmId}, 'sh-test', 'running', '{"networkIpv4":"10.192.0.9"}'::jsonb),
             (${intentId}, ${owner}, ${owner}, 'freestyle', ${`fs-idle-${intentId}`}, 'sh-test', 'running', '{}'::jsonb),
             (${keptId}, ${owner}, ${owner}, 'freestyle', ${`fs-idle-${keptId}`}, 'sh-test', 'running', '{}'::jsonb)`;
  });

  afterAll(async () => {
    if (!dbEnabled) return;
    await sql`delete from cloud_vms where user_id = ${owner}`;
    await closeCloudDbForTests();
    await sql.end();
  });

  const read = async () => {
    const [row] = await sql<{ metadata: Record<string, unknown>; updatedAt: Date; status: string }[]>`
      select provider_metadata as metadata, updated_at as "updatedAt", status from cloud_vms where id = ${rowId}`;
    return row;
  };
  const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
  const repo = vmRepositoryLiveShape;

  for (const operation of ["setting", "observation", "cleared observation", "activity", "decision"] as const) {
    dbTest(`idle metadata stays an object after repeated ${operation} writes`, async () => {
      const id = randomUUID();
      const vmId = `fs-json-${id}`;
      const initial = { networkIpv4: "10.192.0.5", cmuxIdleEpoch: 0, preserved: { value: "keep" } };
      // Bind the serialized JSON as text so the driver cannot serialize it a second time.
      await sql`insert into cloud_vms (id, user_id, billing_team_id, provider, provider_vm_id, image_id, status, provider_metadata)
        values (${id}, ${owner}, ${owner}, 'freestyle', ${vmId}, 'sh-test', 'running', ${JSON.stringify(initial)}::text::jsonb)`;
      try {
        for (const index of [0, 1]) {
          const at = T0 + index * MIN;
          const common = { id, providerVmId: vmId };
          if (operation === "setting") await run(repo.setIdlePauseMinutes!({ ...common, minutes: 30 }));
          else if (operation === "activity") expect(await run(repo.recordVmApiActivity!({ ...common, at }))).toBe(true);
          else if (operation === "decision") await run(repo.recordIdleDecision!({ ...common, checkId: `json-${index}`,
            decision: { at, outcome: "idle", reason: "idle", run: { checked: 1, elapsedMs: 1 } } }));
          else expect(await run(repo.recordIdleObservation!({ ...common, epoch: index, probedAt: at,
            observation: operation === "cleared observation" ? null : { providerVmId: vmId, idleSince: T0, observedAt: at, cpuBusyMs: CPU0 },
          }))).toBe(true);
          const [stored] = await sql<{ kind: string; metadata: Record<string, unknown> }[]>`
            select jsonb_typeof(provider_metadata) as kind, provider_metadata as metadata from cloud_vms where id = ${id}`;
          expect(stored.kind).toBe("object");
          expect(stored.metadata).toMatchObject({ networkIpv4: initial.networkIpv4, preserved: initial.preserved });
          expect(stored.metadata.cmuxIdleEpoch).toBe(operation === "decision" ? 0 : index + 1);
          if (operation === "activity") {
            expect(stored.metadata.cmuxLastApiActivityAt).toBe(at);
            expect(await run(repo.recordVmApiActivity!({ ...common, at: at + 30_000 }))).toBe(false);
          }
        }
      } finally {
        await sql`delete from cloud_vms where id = ${id}`;
      }
    });
  }

  dbTest("resize reservations invalidate an overdue candidate before the cron claims it", async () => {
    for (const kind of ["compute", "disk"] as const) {
      const id = randomUUID();
      const vmId = `fs-resize-${id}`;
      const scope = `resize-idle-${id}`;
      const now = Date.now();
      const metadata = { networkIpv4: "10.192.0.5", cmuxIdleEpoch: 2,
        cmuxResourceReservation: { vcpus: 2, memoryMb: 4096, diskMb: 32768 },
        cmuxIdleObservation: { providerVmId: vmId, idleSince: now - 31 * MIN, observedAt: now - 5 * MIN, cpuBusyMs: CPU0 } };
      await sql`insert into cloud_vms (id, user_id, billing_team_id, provider, provider_vm_id, image_id, status, provider_metadata)
        values (${id}, ${scope}, ${scope}, 'freestyle', ${vmId}, 'sh-test', 'running', ${JSON.stringify(metadata)}::text::jsonb)`;
      try {
        const lookup = { userId: scope, billingTeamId: scope, providerVmId: vmId, provider: "freestyle" as const };
        const candidate = await run(repo.findUserVm(lookup));
        expect(candidate).not.toBeNull();
        const common = { id, userId: scope, billingTeamId: scope, providerVmId: vmId };
        const reserved = kind === "compute"
          ? await run(repo.reserveVmComputeResize!({ ...common, current: metadata.cmuxResourceReservation,
            requested: { vcpus: 4, memoryMb: 4096 },
            resourcePool: { capacity: { vcpus: 20, memoryMb: 40960 }, legacyReservation: { vcpus: 32, memoryMb: 65536 }, planId: "pro" } }))
          : await run(repo.reserveVmResize!({ ...common, currentDiskMb: 32768, storageMb: 65536 }));
        expect(reserved).not.toBeNull();
        const { provider, recorded } = cronFakes([], () => ({ exitCode: 0, stdout: probeLine() }));
        const layer = Layer.mergeAll(
          Layer.succeed(VmRepository, { ...repo, idlePauseCandidates: () => Effect.succeed([candidate!]) }),
          Layer.succeed(VmProviderGateway, provider),
        );
        const summary = await run(enforceVmIdlePause({ now: () => now }).pipe(Effect.provide(layer)));
        expect(summary).toMatchObject({ paused: 0, claim_refused: 1 });
        expect(recorded.paused).toEqual([]);
        const current = (await run(repo.findUserVm(lookup)))!;
        expect(epochOf(current)).toBeGreaterThan(epochOf(candidate!));
        expect(vmLastApiActivityFromRow(current)).toBeGreaterThanOrEqual(now);
        expect(current.providerMetadata?.cmuxIdleObservation).toEqual(metadata.cmuxIdleObservation);
      } finally {
        await sql`delete from cloud_vms where id = ${id}`;
      }
    }
  });

  dbTest("diagnostics preserve populated lifecycle state and newer decisions, including tied timestamps", async () => {
    const original = await read();
    try {
      const observation = { providerVmId, idleSince: T0 - MIN, observedAt: T0, cpuBusyMs: CPU0 };
      const preserved = { ...original.metadata, cmuxIdleEpoch: 7, cmuxIdlePauseClaim: 7,
        cmuxIdleObservation: observation, cmuxLastApiActivityAt: T0 - 2 * MIN };
      await sql`update cloud_vms set provider_metadata = ${JSON.stringify(preserved)}::text::jsonb where id = ${rowId}`;
      const before = await read();
      const decision = { at: T0, outcome: "idle" as const, reason: "idle", run: { checked: 2, elapsedMs: 100 } };
      const write = (checkId: string, value = decision) => run(repo.recordIdleDecision!({
        id: rowId, providerVmId, decision: value, checkId,
      }));
      await write("check-a");
      let row = await read();
      expect(row.updatedAt).toEqual(before.updatedAt);
      expect(row.metadata).toMatchObject(preserved);
      expect(row.metadata.cmuxIdleLastDecision).toEqual({ ...decision, checkId: "check-a" });
      expect(row.metadata.cmuxIdleProbedAt).toBe(T0);
      await write("older", { ...decision, at: T0 - 1 });
      await write("check-a", { ...decision, at: T0 - 1 });
      expect((await read()).metadata.cmuxIdleLastDecision).toEqual({ ...decision, checkId: "check-a" });
      await run(repo.recordIdleDecision!({ id: rowId, providerVmId: "replaced", decision, checkId: "replacement" }));
      expect((await read()).metadata.cmuxIdleLastDecision).toEqual({ ...decision, checkId: "check-a" });
      // A and B have indistinguishable check times: the first stored check (A) wins.
      const competing = { ...decision, reason: "other", run: { checked: 1, elapsedMs: 20 } };
      await write("check-b", competing);
      await write("check-a", { ...decision, run: { checked: 99, elapsedMs: 500 } });
      await write("check-b", { ...competing, run: { checked: 3, elapsedMs: 50 } });
      expect((await read()).metadata.cmuxIdleLastDecision).toEqual({ ...decision, checkId: "check-a", run: { checked: 99, elapsedMs: 500 } });
      // A later check wins, then finalizes. A delayed initial write tied with it cannot replace it either.
      const later = { ...decision, at: T0 + 1 };
      await write("check-later", later);
      await write("check-later", { ...later, run: { checked: 3, elapsedMs: 50 } });
      await write("check-delayed", { ...later, reason: "delayed_initial" });
      expect((await read()).metadata.cmuxIdleLastDecision).toEqual({ ...later, checkId: "check-later", run: { checked: 3, elapsedMs: 50 } });
      // Run totals can also retry an initial write that failed while its timestamp is still newer.
      await write("check-retry", { ...decision, at: T0 + 2 });
      expect((await read()).metadata.cmuxIdleLastDecision).toMatchObject({ at: T0 + 2, checkId: "check-retry" });
      // A paused row still records diagnostics without restoring its idle observation.
      await sql`update cloud_vms set status = 'paused', provider_metadata = provider_metadata - 'cmuxIdleObservation' where id = ${rowId}`;
      await run(repo.recordIdleDecision!({ id: rowId, providerVmId, decision: { ...decision, at: T0 + 3, outcome: "paused" }, checkId: "paused" }));
      row = await read();
      expect(row.status).toBe("paused");
      expect(row.metadata.cmuxIdleObservation).toBeUndefined();
      expect(row.metadata.cmuxIdleEpoch).toBe(7);
      expect(row.metadata.cmuxIdlePauseClaim).toBe(7);
      expect(row.updatedAt).toEqual(before.updatedAt);
      expect(row.metadata.cmuxIdleLastDecision).toMatchObject({ outcome: "paused" });
    } finally {
      await sql`update cloud_vms set status = ${original.status}, provider_metadata = ${JSON.stringify(original.metadata)}::text::jsonb where id = ${rowId}`;
    }
  });

  dbTest("a create stores its idle pause with the row, and a same-key retry keeps the first one", async () => {
    const create = (idlePauseMinutes: 0 | 120 | undefined) => run(repo.beginCreate({
      userId: owner, billingTeamId: owner, billingPlanId: "pro", provider: "freestyle", image: "sh-test",
      maxActiveVms: null, idempotencyKey: `idle-create-${rowId}`, ...(idlePauseMinutes === undefined ? {} : { idlePauseMinutes }),
    }));
    const first = await create(0);
    expect(first.inserted).toBe(true);
    expect(first.vm.providerMetadata?.cmuxIdlePauseMinutes).toBe(0);
    const retry = await create(120);
    expect(retry.inserted).toBe(false);
    expect(retry.vm.id).toBe(first.vm.id);
    expect(retry.vm.providerMetadata?.cmuxIdlePauseMinutes).toBe(0);
    const thirty = await run(repo.beginCreate({
      userId: owner, billingTeamId: owner, billingPlanId: "pro", provider: "freestyle", image: "sh-test",
      maxActiveVms: null, idempotencyKey: `idle-thirty-${rowId}`, idlePauseMinutes: 30,
    }));
    expect(thirty.vm.providerMetadata?.cmuxIdlePauseMinutes).toBe(30);
    const plain = await run(repo.beginCreate({
      userId: owner, billingTeamId: owner, billingPlanId: "pro", provider: "freestyle", image: "sh-test",
      maxActiveVms: null, idempotencyKey: `idle-plain-${rowId}`,
    }));
    expect(plain.vm.providerMetadata?.cmuxIdlePauseMinutes).toBeUndefined();
  });

  dbTest("the cron's writes skip updated_at; a pause and a resume drop the observation; candidates rotate", async () => {
    const start = await read();
    const observation = { providerVmId, idleSince: T0, observedAt: T0, cpuBusyMs: 1_000 };
    expect(await run(repo.recordIdleObservation!({ id: rowId, providerVmId, observation, probedAt: T0, epoch: 0 }))).toBe(true);
    expect(await run(repo.recordVmApiActivity!({ id: rowId, providerVmId, at: T0 }))).toBe(true);
    // Within a minute of the stored time: skipped.
    expect(await run(repo.recordVmApiActivity!({ id: rowId, providerVmId, at: T0 + 30_000 }))).toBe(false);
    let row = await read();
    expect(row.metadata).toEqual({ networkIpv4: "10.192.0.5", cmuxIdleObservation: observation, cmuxIdleProbedAt: T0, cmuxLastApiActivityAt: T0, cmuxIdleEpoch: 2 });
    expect(row.updatedAt.getTime()).toBe(start.updatedAt.getTime());

    // Never checked (a malformed time reads as never) comes before checked.
    const candidates = await run(repo.idlePauseCandidates!({ limit: 10_000 }));
    const ids = candidates.map((c) => c.id);
    expect(ids.indexOf(otherId)).toBeGreaterThanOrEqual(0);
    expect(ids.indexOf(otherId)).toBeLessThan(ids.indexOf(rowId));

    expect(await run(repo.markProviderObservedStatus({ id: rowId, providerVmId, status: "paused", pauseReason: "idle" }))).toBe(true);
    row = await read();
    expect(row.status).toBe("paused");
    expect(row.metadata.cmuxIdleObservation).toBeUndefined();
    expect(row.metadata.cmuxPauseReason).toBe("idle");

    // An observation written behind the pause's back is dropped by the resume.
    await sql`update cloud_vms set provider_metadata = provider_metadata || ${JSON.stringify({ cmuxIdleObservation: observation })}::text::jsonb where id = ${rowId}`;
    const resumed = await run(repo.reservePausedResume({ id: rowId, userId: owner, billingTeamId: owner, providerVmId, maxActiveVms: null }));
    expect(resumed?.status).toBe("running");
    row = await read();
    expect(row.metadata.cmuxIdleObservation).toBeUndefined();

    // Any other status write drops it too, and the reason with it.
    expect(await run(repo.recordIdleObservation!({ id: rowId, providerVmId, observation, probedAt: T0 + MIN, epoch: 4 }))).toBe(true);
    expect(await run(repo.markProviderObservedStatus({ id: rowId, providerVmId, status: "running" }))).toBe(true);
    row = await read();
    expect(row.metadata.cmuxIdleObservation).toBeUndefined();
    expect(row.metadata.cmuxPauseReason).toBeUndefined();
    expect(row.metadata).toMatchObject({ networkIpv4: "10.192.0.5", cmuxIdleProbedAt: T0 + MIN, cmuxLastApiActivityAt: T0 });
  });

  dbTest("the idle fence: stale observations and claims lose; activity, settings, pause and resume move it", async () => {
    const epoch = async () => {
      const [row] = await sql<{ metadata: Record<string, unknown>; status: string }[]>`
        select provider_metadata as metadata, status from cloud_vms where id = ${fenceId}`;
      return { epoch: row.metadata.cmuxIdleEpoch ?? 0, status: row.status, observation: row.metadata.cmuxIdleObservation };
    };
    const at = (idleSince: number) => ({ providerVmId: fenceVmId, idleSince, observedAt: idleSince, cpuBusyMs: 1_000 });
    const observe = (observation: VmIdleObservation | null, fence: number) =>
      run(repo.recordIdleObservation!({ id: fenceId, providerVmId: fenceVmId, observation, probedAt: T0, epoch: fence }));
    expect(await epoch()).toMatchObject({ epoch: 0 });
    expect(await observe(at(T0), 0)).toBe(true);
    expect(await epoch()).toMatchObject({ epoch: 1, observation: at(T0) });
    // Two runs read epoch 0; the second write is stale and changes nothing.
    expect(await observe(at(T0 - 60 * MIN), 0)).toBe(false);
    expect(await epoch()).toMatchObject({ epoch: 1, observation: at(T0) });

    expect(await run(repo.recordVmApiActivity!({ id: fenceId, providerVmId: fenceVmId, at: T0 }))).toBe(true);
    expect(await epoch()).toMatchObject({ epoch: 2 });
    await run(repo.setIdlePauseMinutes!({ id: fenceId, minutes: 60 }));
    expect(await epoch()).toMatchObject({ epoch: 3 });

    // The claim is the cron's last check before the provider pause.
    expect(await run(repo.claimIdlePause!({ id: fenceId, providerVmId: fenceVmId, epoch: 2 }))).toBeNull();
    expect(await run(repo.claimIdlePause!({ id: fenceId, providerVmId: fenceVmId, epoch: 3 }))).toBe(4);
    // The pause records only if nothing moved the fence after the claim.
    expect(await run(repo.markProviderObservedStatus({ id: fenceId, providerVmId: fenceVmId, status: "paused", pauseReason: "idle", expectIdleEpoch: 3 }))).toBe(false);
    expect(await epoch()).toMatchObject({ epoch: 4, status: "running" });
    expect(await run(repo.markProviderObservedStatus({ id: fenceId, providerVmId: fenceVmId, status: "paused", pauseReason: "idle", expectIdleEpoch: 4 }))).toBe(true);
    expect(await epoch()).toMatchObject({ epoch: 5, status: "paused" });
    // A stale fence never records, whatever the row's status.
    expect(await run(repo.markProviderObservedStatus({ id: fenceId, providerVmId: fenceVmId, status: "running", expectIdleEpoch: 4 }))).toBe(false);

    const resumed = await run(repo.reservePausedResume({ id: fenceId, userId: owner, billingTeamId: owner, providerVmId: fenceVmId, maxActiveVms: null }));
    expect(resumed?.status).toBe("running");
    expect(await epoch()).toMatchObject({ epoch: 6, status: "running" });
    // An observation from before the resume is stale.
    expect(await observe(at(T0 - 90 * MIN), 5)).toBe(false);
    expect(await run(repo.markProviderObservedStatus({ id: fenceId, providerVmId: fenceVmId, status: "running" }))).toBe(true);
    expect(await epoch()).toMatchObject({ epoch: 7, observation: undefined });
  });

  dbTest("the pause claim is left in the row until a write settles it; a person's pause is stamped with its fence", async () => {
    const vmId = `fs-idle-${intentId}`;
    const meta = async () => {
      const [row] = await sql<{ metadata: Record<string, unknown>; status: string }[]>`
        select provider_metadata as metadata, status from cloud_vms where id = ${intentId}`;
      return { ...row.metadata, status: row.status } as Record<string, unknown>;
    };
    expect(await run(repo.claimIdlePause!({ id: intentId, providerVmId: vmId, epoch: 0 }))).toBe(1);
    expect(await meta()).toMatchObject({ cmuxIdleEpoch: 1, cmuxIdlePauseClaim: 1 });
    // The next run's observation write settles a claim it found the machine running under.
    expect(await run(repo.recordIdleObservation!({ id: intentId, providerVmId: vmId, observation: null, probedAt: T0, epoch: 1 }))).toBe(true);
    expect((await meta()).cmuxIdlePauseClaim).toBeUndefined();

    expect(await run(repo.claimIdlePause!({ id: intentId, providerVmId: vmId, epoch: 2 }))).toBe(3);
    // A person's pause: reason user, stamped with the fence its write set; the claim is settled.
    expect(await run(repo.markProviderObservedStatus({ id: intentId, providerVmId: vmId, status: "paused", pauseReason: "user" }))).toBe(true);
    let row = await meta();
    expect(row).toMatchObject({ status: "paused", cmuxIdleEpoch: 4, cmuxPauseReason: "user", cmuxPauseIntentEpoch: 4 });
    expect(row.cmuxIdlePauseClaim).toBeUndefined();
    // The status reconciler's paused write keeps the person's stamp and adds none of its own.
    expect(await run(repo.markProviderObservedStatus({ id: intentId, providerVmId: vmId, status: "paused" }))).toBe(true);
    expect(await meta()).toMatchObject({ cmuxIdleEpoch: 5, cmuxPauseReason: "user", cmuxPauseIntentEpoch: 4 });

    // The compensating resume claims any live status at its fence, and records running only at the claimed one.
    expect(await run(repo.claimIdleResume!({ id: intentId, providerVmId: vmId, epoch: 4 }))).toBeNull();
    expect(await run(repo.claimIdleResume!({ id: intentId, providerVmId: vmId, epoch: 5 }))).toBe(6);
    expect(await run(repo.markProviderObservedStatus({ id: intentId, providerVmId: vmId, status: "running", expectIdleEpoch: 6 }))).toBe(true);
    row = await meta();
    expect(row).toMatchObject({ status: "running", cmuxIdleEpoch: 7 });
    expect(row.cmuxPauseReason).toBeUndefined();
    expect(row.cmuxPauseIntentEpoch).toBeUndefined();
  });

  dbTest("the status reconciler's write keeps an unresolved claim, and a claimed row stays a candidate while paused", async () => {
    const vmId = `fs-idle-${keptId}`;
    const meta = async () => {
      const [row] = await sql<{ metadata: Record<string, unknown>; status: string }[]>`
        select provider_metadata as metadata, status from cloud_vms where id = ${keptId}`;
      return { ...row.metadata, status: row.status } as Record<string, unknown>;
    };
    expect(await run(repo.claimIdlePause!({ id: keptId, providerVmId: vmId, epoch: 0 }))).toBe(1);
    expect(await run(repo.markProviderObservedStatus({ id: keptId, providerVmId: vmId, status: "paused" }))).toBe(true);
    expect(await meta()).toMatchObject({ status: "paused", cmuxIdleEpoch: 2, cmuxIdlePauseClaim: 1 });
    const candidates = await run(repo.idlePauseCandidates!({ limit: 10_000 }));
    expect(candidates.map((c) => c.id)).toContain(keptId);
    // The cron's fenced running record settles it; the row is no longer a candidate once paused without one.
    expect(await run(repo.claimIdleResume!({ id: keptId, providerVmId: vmId, epoch: 2 }))).toBe(3);
    expect(await run(repo.markProviderObservedStatus({ id: keptId, providerVmId: vmId, status: "running", expectIdleEpoch: 3 }))).toBe(true);
    expect((await meta()).cmuxIdlePauseClaim).toBeUndefined();
    expect(await run(repo.markProviderObservedStatus({ id: keptId, providerVmId: vmId, status: "paused" }))).toBe(true);
    expect((await run(repo.idlePauseCandidates!({ limit: 10_000 }))).map((c) => c.id)).not.toContain(keptId);

    // A deliberate pause's intent moves the fence before its provider effects; its own paused write still
    // lands (it is not fenced) and replaces the intent with its stamp.
    expect(await meta()).toMatchObject({ cmuxIdleEpoch: 5 });
    expect(await run(repo.recordPauseIntent!({ id: keptId, providerVmId: vmId, cause: "user" }))).toBe(6);
    expect(await meta()).toMatchObject({ cmuxIdleEpoch: 6, cmuxPendingPause: { cause: "user", epoch: 6 } });
    expect(await run(repo.claimIdleResume!({ id: keptId, providerVmId: vmId, epoch: 5 }))).toBeNull();
    // Outstanding: no idle resume claim even at the current fence.
    expect(await run(repo.claimIdleResume!({ id: keptId, providerVmId: vmId, epoch: 6 }))).toBeNull();
    // A pause's own clear is fenced on its epoch: an older one clears nothing.
    await run(repo.clearPauseIntent!({ id: keptId, epoch: 5 }));
    expect((await meta()).cmuxPendingPause).toBeDefined();
    expect(await run(repo.markProviderObservedStatus({ id: keptId, providerVmId: vmId, status: "paused", pauseReason: "user" }))).toBe(true);
    const settled = await meta();
    expect(settled).toMatchObject({ cmuxIdleEpoch: 7, cmuxPauseReason: "user", cmuxPauseIntentEpoch: 7 });
    expect(settled.cmuxPendingPause).toBeUndefined();

    // A pause that failed clears its intent, and claims work again.
    expect(await run(repo.recordPauseIntent!({ id: keptId, providerVmId: vmId, cause: "user" }))).toBe(8);
    await run(repo.clearPauseIntent!({ id: keptId, epoch: 8 }));
    expect((await meta()).cmuxPendingPause).toBeUndefined();
    expect(await run(repo.claimIdleResume!({ id: keptId, providerVmId: vmId, epoch: 8 }))).toBe(9);
    expect(await run(repo.markProviderObservedStatus({ id: keptId, providerVmId: vmId, status: "running", expectIdleEpoch: 9 }))).toBe(true);
    // No idle pause claim over an outstanding intent on a running machine; an abandoned one no longer holds.
    expect(await run(repo.recordPauseIntent!({ id: keptId, providerVmId: vmId, cause: "allowance" }))).toBe(11);
    expect(await run(repo.claimIdlePause!({ id: keptId, providerVmId: vmId, epoch: 11 }))).toBeNull();
    await sql`update cloud_vms set provider_metadata = jsonb_set(provider_metadata, '{cmuxPendingPause,requestedAt}', ${String(Date.now() - 2 * 60 * MIN)}::jsonb) where id = ${keptId}`;
    expect(await run(repo.claimIdlePause!({ id: keptId, providerVmId: vmId, epoch: 11 }))).toBe(12);
  });
});

// Production machines bake cmux-tui a9b104f3 (2026-10-14), from before the
// daemon served `subscribe-activity` and before `cmux-tui acp` existed. Their
// daemon answers the probe's request with serde's unknown-variant error and
// their CLI refuses `acp` as an unknown resource scope. Those two answers, and
// only those, put the probe in legacy mode: it decides from terminals, ssh,
// inbound connections, CPU and API calls, and says so in its reason. Anything
// else the daemon or acpmux answers stays unknown and never pauses.
describe("a shell running a command", () => {
  // pts/0's foreground group is only a shell. At its prompt that is idle; a
  // shell that is itself the command (`bash -c ...`, `sh script.sh`) is not.
  const shellOnly = (comm: string, cmdline: string[]) => ({
    "100/stat": stat(100, comm, 100, 100, PTS0, 100),
    "100/cmdline": cmdline.join("\0") + "\0",
    "net/tcp": TCP_HEADER,
  });

  test("bash -c, sh -lc and a shell running a script are busy terminals", async () => {
    for (const cmdline of [["bash", "-c", "read -t 3600"], ["sh", "-lc", "sleep 600"], ["bash", "deploy.sh"], ["/bin/bash", "-e", "./run.sh", "x"],
      // -c after -s still runs it; a bare - ends options like --; an empty rcfile operand is still an operand.
      ["bash", "-s", "-c", "read -t 3600"], ["bash", "-", "deploy.sh"], ["bash", "--rcfile", "", "deploy.sh"]]) {
      const comm = path.basename(cmdline[0]);
      expect({ cmdline, busy: (await runProbeScript(shellOnly(comm, cmdline), "NONE")).busy_terminals }).toEqual({ cmdline, busy: 1 });
    }
  });

  test("a login or interactive shell at its prompt stays idle", async () => {
    for (const [comm, cmdline] of [["bash", ["-bash"]], ["bash", ["bash"]], ["zsh", ["zsh", "-l"]], ["bash", ["bash", "-i"]], ["bash", ["bash", "--login"]],
      // Option operands are not scripts: an rcfile, a set -o option, a shopt name; -s reads commands from stdin.
      ["bash", ["bash", "--rcfile", "/home/cmux/.cmux/bashrc", "-i"]], ["bash", ["bash", "--init-file", "x.sh"]],
      ["bash", ["bash", "-o", "emacs"]], ["bash", ["bash", "+O", "extglob"]], ["zsh", ["zsh", "-o", "vi"]],
      ["bash", ["bash", "-s", "arg"]], ["bash", ["bash", "-io", "emacs"]], ["bash", ["bash", "-"]]] as const) {
      expect({ cmdline, busy: (await runProbeScript(shellOnly(comm, [...cmdline]), "NONE")).busy_terminals }).toEqual({ cmdline, busy: 0 });
    }
  });
});

describe("unreadable activity sources", () => {
  test("a process whose stat or cmdline cannot be read makes terminals and ssh unknown; a vanished one is skipped", async () => {
    const base = {
      "100/stat": stat(100, "zsh", 100, 100, PTS0, 100),
      "100/cmdline": "-zsh\0",
      "net/tcp": TCP_HEADER,
    };
    // pid 300 exited between the listing and the read: no stat, no cmdline.
    const vanished = await runProbeScript({ ...base, "300/environ": "" }, "NONE");
    expect({ busy: vanished.busy_terminals, ssh: vanished.ssh_sessions }).toEqual({ busy: 0, ssh: 0 });
    // A stat that cannot be read (here a directory), or that does not parse.
    for (const broken of [{ "300/stat/x": "" }, { "300/stat": "garbage" }] as Record<string, string>[]) {
      const out = await runProbeScript({ ...base, ...broken }, "NONE");
      expect({ broken, busy: out.busy_terminals, ssh: out.ssh_sessions }).toEqual({ broken, busy: null, ssh: null });
    }
    // A cmdline that cannot be read hides a possible ssh session.
    const noCmdline = await runProbeScript({ ...base, "400/stat": stat(400, "sshd", 400, 400, 0, -1), "400/cmdline/x": "" }, "NONE");
    expect(noCmdline.ssh_sessions).toBeNull();
    // Unknown, so it never pauses.
    expect(parseVmIdleProbe(JSON.stringify({ v: 1, ...noCmdline, cpu_busy_ms: CPU0 }))).toBeNull();
  });

  test("a network table the probe cannot read is unknown, not zero connections", async () => {
    // No /proc/net/tcp at all.
    expect((await runProbeScript({ "net/tcp6": TCP_HEADER }, "NONE")).inbound_connections).toBeNull();
    // tcp read fine, tcp6 is there but cannot be read (here a directory).
    const unreadable6 = await runProbeScript({ "net/tcp": TCP_HEADER, "net/tcp6/x": "" }, "NONE");
    expect(unreadable6.inbound_connections).toBeNull();
    // tcp read fine and tcp6 does not exist (IPv6 disabled): no IPv6 connections.
    expect((await runProbeScript({ "net/tcp": TCP_HEADER }, "NONE")).inbound_connections).toBe(0);
  });

  test("a probe line without a connection count is unknown and never pauses", () => {
    const line = JSON.stringify({ v: 1, daemon: { attached_clients: 0, live_agents: 0, last_user_input_at_ms: null, last_agent_action_at_ms: null }, acpmux: { busy_sessions: 0, last_updated_at_ms: null }, busy_terminals: 0, ssh_sessions: 0, inbound_connections: null, cpu_busy_ms: CPU0 });
    const probe = parseVmIdleProbe(line);
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe, previous, now: T0 }))
      .toEqual({ pause: false, reason: "unknown:probe", observation: null });
  });
});

describe("legacy daemon fallback", () => {
  // serde_json's Display ends the message with the position (server.rs: format!("bad request: {error}")).
  const LEGACY_DAEMON_ERROR = "bad request: unknown variant `subscribe-activity`, expected one of `hello`, `list-workspaces`, `attach` at line 1 column 31";

  async function withDaemonSocket(answer: string, run: (socketPath: string) => Promise<void>) {
    const dir = mkdtempSync(path.join(tmpdir(), "cmux-idle-sock-"));
    const socketPath = path.join(dir, "cloud.sock");
    const server = createServer((conn) => {
      conn.once("data", () => conn.end(answer));
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    try {
      await run(socketPath);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  }

  test("a legacy machine still counts a port forwarded through the daemon link", async () => {
    await withDaemonSocket(JSON.stringify({ id: null, ok: false, error: LEGACY_DAEMON_ERROR }) + "\n", async (socketPath) => {
      const out = await runProbeScript(FORWARDED_PORT_PROC, "NONE", { daemonSocket: socketPath });
      expect(out.daemon).toEqual({ legacy: true });
      expect(out.inbound_connections).toBe(1);
      const probe = parseVmIdleProbe(JSON.stringify({ v: 1, ...out, cpu_busy_ms: CPU0 }));
      expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe, previous: null, now: T0 }))
        .toMatchObject({ pause: false, reason: "active:inbound_connections;legacy_daemon" });
    });
  });

  const idleFiles = {
    "100/stat": stat(100, "bash", 100, 100, PTS0, 100),
    "net/tcp": TCP_HEADER + tcpRow(`00000000:0539`, "00000000:0000", "0A"),
    "net/tcp6": TCP_HEADER,
  };

  test("a daemon that refuses subscribe-activity as an unknown command reads as legacy", async () => {
    await withDaemonSocket(JSON.stringify({ id: null, ok: false, error: LEGACY_DAEMON_ERROR }) + "\n", async (socketPath) => {
      expect((await runProbeScript(idleFiles, "NONE", { daemonSocket: socketPath })).daemon).toEqual({ legacy: true });
    });
  });

  test("any other daemon refusal, or garbage, stays unknown", async () => {
    for (const answer of [
      JSON.stringify({ id: 1, ok: false, error: "bad request: invalid client_id" }) + "\n",
      JSON.stringify({ id: 1, ok: false, error: "unknown variant elsewhere" }) + "\n",
      "not json\n",
      "",
    ]) {
      await withDaemonSocket(answer, async (socketPath) => {
        expect((await runProbeScript(idleFiles, "NONE", { daemonSocket: socketPath })).daemon).toBeNull();
      });
    }
  });

  test("a CLI without the acp subcommand reads as no acpmux; any other acpmux error stays unknown", async () => {
    const json = JSON.stringify({ code: "usage.invalid", message: 'unknown resource scope "acp".', details: {}, retryable: false }) + "\n";
    const human = 'cmux: unknown resource scope "acp". Did you mean `app`?\n';
    for (const acpmuxStatusError of [json, human]) {
      expect((await runProbeScript(idleFiles, "ERR", { acpmuxStatusError })).acpmux).toEqual({ busy_sessions: 0, last_updated_at_ms: null });
    }
    for (const acpmuxStatusError of ["", "acpmux: permission denied\n", 'unknown resource scope "acpx".\n']) {
      expect((await runProbeScript(idleFiles, "ERR", { acpmuxStatusError })).acpmux).toBeNull();
    }
  });

  test("only the exact a9b104f3 daemon refusal is legacy: lookalike commands and embedded copies stay unknown", async () => {
    for (const error of [
      // A later command whose name starts the same way.
      "bad request: unknown variant `subscribe-activity-v2`, expected one of `hello`, `subscribe-activity`",
      // The refusal quoted inside another error.
      "relay: bad request: unknown variant `subscribe-activity`, expected one of `hello`",
      // Same words, not serde's shape.
      "bad request: unknown variant subscribe-activity",
      // The refusal with trailing diagnostics, or with a further line after it.
      `${LEGACY_DAEMON_ERROR}; daemon restarting`,
      "bad request: unknown variant `subscribe-activity`, expected one of `hello`, `attach` (retry with --verbose)",
      `${LEGACY_DAEMON_ERROR}\npanicked at server.rs:6316`,
      // Not a whole serde variant list.
      "bad request: unknown variant `subscribe-activity`, expected one of `hello`, ",
    ]) {
      await withDaemonSocket(JSON.stringify({ id: null, ok: false, error }) + "\n", async (socketPath) => {
        expect((await runProbeScript(idleFiles, "NONE", { daemonSocket: socketPath })).daemon).toBeNull();
      });
    }
    // The exact refusal is legacy: serde's one, two or many expected variants, with or without its position.
    for (const error of [
      LEGACY_DAEMON_ERROR,
      "bad request: unknown variant `subscribe-activity`, expected one of `hello`, `list-workspaces`, `attach`",
      "bad request: unknown variant `subscribe-activity`, expected `hello`",
      "bad request: unknown variant `subscribe-activity`, expected `hello` or `attach` at line 1 column 31",
      `${LEGACY_DAEMON_ERROR}\n`,
    ]) {
      await withDaemonSocket(JSON.stringify({ id: null, ok: false, error }) + "\n", async (socketPath) => {
        expect((await runProbeScript(idleFiles, "NONE", { daemonSocket: socketPath })).daemon).toEqual({ legacy: true });
      });
    }
  });

  test("only the exact a9b104f3 acp refusal means no acpmux: other codes and embedded copies stay unknown", async () => {
    const refusal = 'unknown resource scope "acp".';
    for (const acpmuxStatusError of [
      // Another code with the same message.
      JSON.stringify({ code: "transport.failed", message: refusal, details: {}, retryable: false }) + "\n",
      // The refusal inside other diagnostics.
      `warning: config unreadable\ncmux: ${refusal}\n`,
      `cmux: ${refusal} while starting acpmux\n`,
      JSON.stringify({ code: "usage.invalid", message: `wrapper: ${refusal}`, details: {}, retryable: false }) + "\n",
    ]) {
      expect((await runProbeScript(idleFiles, "ERR", { acpmuxStatusError })).acpmux).toBeNull();
    }
    for (const acpmuxStatusError of [
      JSON.stringify({ code: "usage.invalid", message: `${refusal} Did you mean \`app\`?`, details: {}, retryable: false }) + "\n",
      `cmux: ${refusal}\n`,
    ]) {
      expect((await runProbeScript(idleFiles, "ERR", { acpmuxStatusError })).acpmux).toEqual({ busy_sessions: 0, last_updated_at_ms: null });
    }
  });

  test("the probe command keeps acp status errors in English and hands them to the script", () => {
    const command = vmIdleProbeCommand(["10.192.0.5"]);
    expect(command).toContain(`LC_ALL=C "$CMUX_TUI_BIN" acp --json daemon status`);
    expect(command).toContain(`CMUX_IDLE_ACPMUX_ERR="$t.err"`);
    expect(command).toContain(`rm -f "$t" "$t.err"`);
  });

  test("the probe line's legacy daemon parses; a legacy machine idle for the whole timeout pauses, tagged", () => {
    const line = JSON.stringify({ v: 1, daemon: { legacy: true }, acpmux: { busy_sessions: 0, last_updated_at_ms: null }, busy_terminals: 0, ssh_sessions: 0, inbound_connections: 0, cpu_busy_ms: CPU0 });
    const probe = parseVmIdleProbe(line);
    expect(probe?.daemon).toBe("legacy");
    const { pausedAfterMinutes, decision } = runCron(() => probe, 60);
    expect(pausedAfterMinutes).toBe(30);
    expect(decision?.reason).toBe("idle_timeout;legacy_daemon");
  });

  test("on a legacy machine a busy terminal, ssh, an inbound connection, CPU or an API call keeps it awake", () => {
    const legacy = (overrides: Partial<VmIdleProbe> = {}) => idleProbe({ daemon: "legacy", ...overrides });
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 };
    const decide = (probe: VmIdleProbe, lastApiActivityAt: number | null = null) =>
      decideVmIdlePause({ providerVmId: VM, minutes: 30, probe, previous, now: T0, lastApiActivityAt });
    expect(decide(legacy({ busyTerminals: 1 }))).toMatchObject({ pause: false, reason: "active:busy_terminals;legacy_daemon" });
    expect(decide(legacy({ sshSessions: 1 })).pause).toBe(false);
    expect(decide(legacy({ inboundConnections: 1 })).pause).toBe(false);
    expect(decide(legacy({ cpuBusyMs: CPU0 + 5 * MIN })).pause).toBe(false);
    expect(decide(legacy(), T0 - 10 * MIN)).toMatchObject({ pause: false, reason: "idle;legacy_daemon" });
    expect(decide(legacy())).toMatchObject({ pause: true, reason: "idle_timeout;legacy_daemon" });
  });

  test("the cron pauses an idle legacy machine through the pause path", async () => {
    const row = machineRow({
      providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0 } },
    });
    const { recorded, layer } = cronFakes([row], () => ({ exitCode: 0, stdout: probeLine({ daemon: { legacy: true } }) }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 1, unknown: 0 });
    expect(recorded.paused).toEqual([VM]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused", pauseReason: "idle" }]);
  });
});


describe("idle pause diagnostics", () => {
  test("each decision is readable through status without changing the activity fence", async () => {
    const rows = [machineRow()];
    const before = rows[0].updatedAt;
    const { layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(rows[0].updatedAt).toEqual(before);
    expect(epochOf(rows[0])).toBe(1); // Only the observation advances it.
    const entry = await Effect.runPromise(getVm({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: VM }).pipe(Effect.provide(layer)));
    expect(entry).toMatchObject({ idlePause: {
      minutes: 30, lastCheckedAt: T0, idleSince: T0, lastApiActivityAt: null, privateAddressKnown: true,
      lastDecision: { at: T0, outcome: "idle", reason: "idle", run: { checked: 1 } },
    } });
    expect(typeof entry.idlePause.lastDecision?.run.elapsedMs).toBe("number");
  });

  test("a failed diagnostics write does not cancel checks of other machines", async () => {
    const rows = [machineRow({ providerMetadata: { cmuxIdlePauseMinutes: 0 } }), machineRow({ id: "row-2", providerVmId: "fs-2" })];
    const { repo, layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    let failedWrites = 0;
    const unreliableRepo: VmRepositoryShape = { ...repo, recordIdleDecision: (input) => {
      if (input.id !== "row-1") return repo.recordIdleDecision!(input);
      failedWrites += 1;
      return Effect.fail(new VmDatabaseError({ operation: "recordIdleDecision", cause: new Error("simulated write failure") }));
    } };
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(
      Effect.provideService(VmRepository, unreliableRepo), Effect.provide(layer),
    ));
    expect(failedWrites).toBe(2); // The injected layer must handle both writes.
    expect(summary).toMatchObject({ checked: 2, off: 1, idle: 1 });
    expect(rows[1].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ outcome: "idle", run: { checked: 2 } });
  });

  test("status handles missing and malformed diagnostics and exposes only the documented fields", async () => {
    const rows = [machineRow({ providerMetadata: {} })];
    const { layer } = cronFakes(rows, () => "fails");
    const read = () => Effect.runPromise(getVm({ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: VM }).pipe(Effect.provide(layer)));
    expect((await read()).idlePause).toEqual({ minutes: 30, lastCheckedAt: null, idleSince: null,
      lastApiActivityAt: null, privateAddressKnown: false, lastDecision: null });
    for (const invalid of [null, {}, { at: T0, outcome: "invented", reason: "idle", run: { checked: 1, elapsedMs: 2 } }]) {
      rows[0] = { ...rows[0], providerMetadata: { cmuxIdleLastDecision: invalid } };
      expect((await read()).idlePause.lastDecision).toBeNull();
    }
    rows[0] = { ...rows[0], providerMetadata: { cmuxIdleLastDecision: {
      at: T0, outcome: "idle", reason: "idle", internal: "omit", run: { checked: 1, elapsedMs: 2, internal: "omit" },
    } } };
    expect((await read()).idlePause.lastDecision).toEqual({ at: T0, outcome: "idle", reason: "idle", run: { checked: 1, elapsedMs: 2 } });
  });

  test.each([
    ["off", { cmuxIdlePauseMinutes: 0 }, probeLine(), "off"],
    ["unknown", { networkIpv4: "" }, probeLine(), "unknown:address"],
    ["unknown", {}, "garbled", "unknown:probe"],
    ["active", {}, probeLine({ busy_terminals: 1 }), "active:busy_terminals"],
  ] as const)("stores %s with its reason", async (outcome, metadata, stdout, reason) => {
    const rows = [machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", ...metadata } })];
    const { layer } = cronFakes(rows, () => ({ exitCode: 0, stdout }));
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(rows[0].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ at: T0, outcome, reason, run: { checked: 1 } });
  });

  test("a rejected claim has its own outcome and fence reason instead of reporting guest activity", async () => {
    const rows = [machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: {
      providerVmId: VM, idleSince: T0 - 40 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0,
    } } })];
    const { layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), {
      duringProbe: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
    });
    expect(await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer))))
      .toMatchObject({ paused: 0, claim_refused: 1, active: 0 });
    expect(rows[0].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ outcome: "claim_refused", reason: "api_activity_changed" });
    expect(rows[0].providerMetadata?.cmuxIdleProbedAt).toBe(T0);
  });

  test("provider errors and a lost observation fence remain visible", async () => {
    const rows = [machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: {
      providerVmId: VM, idleSince: T0 - 40 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0,
    } } })];
    const failing = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }), { pauseFails: "refused", statusFailures: 1 });
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(failing.layer)));
    expect(rows[0].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ outcome: "error", reason: "check_failed" });
    const fresh = [machineRow()];
    const overlapping = cronFakes(fresh, () => ({ exitCode: 0, stdout: probeLine() }), {
      duringProbe: (repo) => Effect.runSync(repo.recordVmApiActivity!({ id: "row-1", providerVmId: VM, at: T0 })),
    });
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(overlapping.layer)));
    expect(fresh[0].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ outcome: "aborted", reason: "observation_fence_changed" });
  });

  test("a paused row still records the check and all checked rows carry final run counts", async () => {
    const rows = [machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: {
      providerVmId: VM, idleSince: T0 - 40 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: CPU0,
    } } }), machineRow({ id: "row-2", providerVmId: "fs-2" })];
    const { layer } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(rows[0].providerMetadata?.cmuxIdleLastDecision).toMatchObject({ outcome: "paused", reason: "idle_timeout" });
    for (const row of rows) {
      expect(row.providerMetadata?.cmuxIdleProbedAt).toBe(T0);
      const decision = row.providerMetadata?.cmuxIdleLastDecision as { run: { checked: number; elapsedMs: number } };
      expect(decision).toMatchObject({ run: { checked: 2 } });
      expect(typeof decision.run.elapsedMs).toBe("number");
    }
  });
});
