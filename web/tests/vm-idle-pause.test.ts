import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  decideVmIdlePause,
  parseVmIdleProbe,
  vmIdleObservationFromRow,
  vmIdlePauseMinutesFromRow,
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
import { enforceVmIdlePause } from "../services/vms/idlePauseJob";
import { parseCreateIdlePause, parseIdlePauseBody } from "../services/vms/idlePauseRoute";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, vmRepositoryLiveShape, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { execVm, pauseVm, setVmIdlePause } from "../services/vms/workflows";
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

function idleProbe(overrides: Partial<VmIdleProbe> = {}): VmIdleProbe {
  return {
    daemon: { attachedClients: 0, liveAgents: 0, lastUserInputAt: null, lastAgentActionAt: null },
    acpmux: { busySessions: 0, lastUpdatedAt: null },
    busyTerminals: 0,
    sshSessions: 0,
    inboundConnections: 0,
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

  test("an attached client, a foreground command, an ssh login or a forwarded-port connection keeps it awake", () => {
    const cases: Array<[VmIdleProbe, string]> = [
      [idleProbe({ daemon: { attachedClients: 1, liveAgents: 0, lastUserInputAt: null, lastAgentActionAt: null } }), "active:attached_clients"],
      [idleProbe({ busyTerminals: 1 }), "active:busy_terminals"],
      [idleProbe({ sshSessions: 1 }), "active:ssh_sessions"],
      [idleProbe({ inboundConnections: 2 }), "active:inbound_connections"],
    ];
    for (const [probe, reason] of cases) {
      expect(runCron(() => probe, 6 * 60).pausedAfterMinutes).toBeNull();
      expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe, previous: null, now: T0 })).toEqual({ pause: false, reason, observation: null });
    }
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
    const previous = { providerVmId: VM, idleSince: T0 - 40 * MIN, observedAt: T0 - 5 * MIN };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: ahead, previous, now: T0 }).pause).toBe(false);
  });

  test("an unknown probe never pauses and does not carry the stretch", () => {
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN };
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
    const stale = { providerVmId: VM, idleSince: T0 - 120 * MIN, observedAt: T0 - VM_IDLE_OBSERVATION_MAX_GAP_MS - 1 };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: stale, now: T0 })).toEqual({
      pause: false, reason: "idle", observation: { providerVmId: VM, idleSince: T0, observedAt: T0 },
    });
    const otherVm = { providerVmId: "fs-other", idleSince: T0 - 120 * MIN, observedAt: T0 - 5 * MIN };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: otherVm, now: T0 }).pause).toBe(false);
    const fresh = { providerVmId: VM, idleSince: T0 - 30 * MIN, observedAt: T0 - 5 * MIN };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: fresh, now: T0 }).pause).toBe(true);
  });

  test("Off never pauses, even idle for days", () => {
    expect(runCron(() => idleProbe(), 3 * 24 * 60, 0).pausedAfterMinutes).toBeNull();
    const previous = { providerVmId: VM, idleSince: T0 - 3 * 24 * 60 * MIN, observedAt: T0 - 5 * MIN };
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
    const command = vmIdleProbeCommand(["10.192.0.5", "fd00:7::5", "10.0.0.1; rm -rf /"]);
    expect(command).toContain(`CMUX_IDLE_PRIVATE_ADDRESSES='10.192.0.5,fd00:7::5'`);
    expect(command).toContain(`acp --json daemon status`);
    expect(command).toContain(`*'"running":false'*`);
    expect(command).toContain("setpriv");
    expect(command).not.toContain("rm -rf");
  });
});

/** A fake /proc and daemon socket file for the guest script. */
function fakeProc(files: Record<string, string>): string {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-idle-proc-"));
  for (const [rel, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    writeFileSync(path.join(root, rel), text);
  }
  return root;
}

const PTS0 = (136 << 8) | 0;
const PTS1 = (136 << 8) | 1;
const TTYS0 = (4 << 8) | 64;
const stat = (pid: number, comm: string, pgrp: number, sid: number, tty: number, tpgid: number) =>
  `${pid} (${comm}) S 1 ${pgrp} ${sid} ${tty} ${tpgid} 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0\n`;
const TCP_HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";
const tcpRow = (local: string, remote: string, state: string) => `   0: ${local} ${remote} ${state} 00000000:00000000 00:00000000 00000000  1000        0 1 1\n`;
// 10.192.0.5 little-endian, ports 1337 (0539), 3000 (0BB8), 22 (0016).
const VPC = "0500C00A";

async function runProbeScript(files: Record<string, string>, acpmux: string): Promise<Record<string, unknown>> {
  const root = fakeProc(files);
  writeFileSync(path.join(root, "acpmux.json"), acpmux);
  writeFileSync(path.join(root, "daemon-socket"), path.join(root, "no-such.sock"));
  const result = await runChild("python3", ["-I", "-c", VM_IDLE_PROBE_SCRIPT], {
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      CMUX_IDLE_PROC_ROOT: root,
      CMUX_IDLE_ACPMUX: path.join(root, "acpmux.json"),
      CMUX_IDLE_DAEMON_SOCKET_FILE: path.join(root, "daemon-socket"),
      CMUX_IDLE_PRIVATE_ADDRESSES: "10.192.0.5,fd00:7::5",
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
        + tcpRow(`00000000000000000000000000000000:0539`, "00000000000000000000000000000000:0000", "0A")
        + tcpRow(`${local6}:0539`, `${remote6}:C000`, "01")
        + tcpRow(`${mapped}:0539`, "0000000000000000FFFF00000900C00A:C001", "01"),
    }, "NONE");
    expect(out.inbound_connections).toBe(3);
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

/** What the live markProviderObservedStatus leaves in providerMetadata (repository.ts observedStatusMetadata). */
function observedStatusMetadata(metadata: Record<string, unknown>, input: ObservedStatusInput): Record<string, unknown> {
  const base = withoutObservation(metadata);
  if (input.status !== "paused") return omit(base, "cmuxPauseReason");
  return input.pauseReason ? { ...base, cmuxPauseReason: input.pauseReason } : base;
}

/**
 * Fake repository and provider layers. The repository mirrors the live writes
 * on `rows`: a status write drops the idle observation, the cron's write
 * stores the observation and the check time, and `resume` does what
 * reservePausedResume does. `reread` changes what the pre-pause re-read sees.
 */
function cronFakes(
  rows: CloudVmRow[],
  probeOut: (vmId: string) => { exitCode: number; stdout: string } | "fails",
  fakeOptions: { readonly reread?: (row: CloudVmRow) => CloudVmRow | null } = {},
) {
  const recorded = {
    execs: [] as Array<{ vmId: string; asRoot: boolean | undefined; command: string }>,
    paused: [] as string[],
    statuses: [] as Array<{ id: string; status: string; pauseReason?: string }>,
    observations: [] as Array<{ id: string; observation: VmIdleObservation | null }>,
    probedAt: [] as Array<{ id: string; probedAt: number }>,
    apiActivity: [] as Array<{ id: string; at: number }>,
    events: [] as Array<Record<string, unknown>>,
    minutes: [] as Array<{ id: string; minutes: number }>,
  };
  const update = (id: string, change: (row: CloudVmRow) => CloudVmRow) => {
    const index = rows.findIndex((r) => r.id === id);
    if (index >= 0) rows[index] = change(rows[index]);
  };
  const repo = {
    // Like the live query: running machines only.
    idlePauseCandidates: () => Effect.sync(() => rows.filter((r) => r.status === "running")),
    recordIdleObservation: (input: { id: string; providerVmId: string; observation: VmIdleObservation | null; probedAt: number }) => Effect.sync(() => {
      recorded.observations.push({ id: input.id, observation: input.observation });
      recorded.probedAt.push({ id: input.id, probedAt: input.probedAt });
      update(input.id, (row) => row.status !== "running" || row.providerVmId !== input.providerVmId ? row : {
        ...row,
        providerMetadata: {
          ...withoutObservation(row.providerMetadata ?? {}),
          ...(input.observation ? { cmuxIdleObservation: input.observation } : {}),
          cmuxIdleProbedAt: input.probedAt,
        },
      });
      return true;
    }),
    recordVmApiActivity: (input: { id: string; providerVmId: string; at: number }) => Effect.sync(() => {
      recorded.apiActivity.push({ id: input.id, at: input.at });
      update(input.id, (row) => ({ ...row, providerMetadata: { ...(row.providerMetadata ?? {}), cmuxLastApiActivityAt: input.at } }));
      return true;
    }),
    findUserVm: (input: { providerVmId: string }) => Effect.sync(() => {
      const row = rows.find((r) => r.providerVmId === input.providerVmId && r.status !== "destroyed") ?? null;
      return row && fakeOptions.reread ? fakeOptions.reread(row) : row;
    }),
    markProviderObservedStatus: (input: ObservedStatusInput) => Effect.sync(() => {
      recorded.statuses.push({ id: input.id, status: input.status, ...(input.pauseReason ? { pauseReason: input.pauseReason } : {}) });
      update(input.id, (row) => ({
        ...row,
        status: input.status,
        updatedAt: new Date(row.updatedAt.getTime() + 1),
        providerMetadata: observedStatusMetadata(row.providerMetadata ?? {}, input),
      }));
      return true;
    }),
    recordUsageEvent: (input: { metadata?: Record<string, unknown> }) => {
      recorded.events.push(input.metadata ?? {});
      return Effect.void;
    },
    setIdlePauseMinutes: (input: { id: string; minutes: number }) => {
      recorded.minutes.push(input);
      return Effect.void;
    },
  } as unknown as VmRepositoryShape;
  const provider = {
    exec: (_provider: string, vmId: string, command: string, options?: { asRoot?: boolean }) => {
      recorded.execs.push({ vmId, asRoot: options?.asRoot, command });
      const out = probeOut(vmId);
      return out === "fails" ? Effect.fail(new Error("exec failed")) : Effect.succeed({ ...out, stderr: "" });
    },
    pause: (_provider: string, vmId: string) => {
      recorded.paused.push(vmId);
      return Effect.void;
    },
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
  /** A resume as reservePausedResume writes it: running again, observation dropped, updatedAt moved. */
  const resume = (id: string, at: number) => update(id, (row) => ({
    ...row,
    status: "running",
    updatedAt: new Date(at),
    providerMetadata: withoutObservation(row.providerMetadata ?? {}),
  }));
  return { recorded, layer, resume };
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
  ...overrides,
});

describe("idle pause cron", () => {
  test("pauses an idle machine past its timeout through the pause path, with reason idle", async () => {
    const idle = machineRow({
      providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN } },
    });
    const { recorded, layer } = cronFakes([idle], () => ({ exitCode: 0, stdout: probeLine() }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 1, errors: 0 });
    expect(recorded.execs).toHaveLength(1);
    expect(recorded.execs[0]).toMatchObject({ vmId: VM, asRoot: true });
    expect(recorded.execs[0].command).toContain("10.192.0.5");
    expect(recorded.paused).toEqual([VM]);
    expect(recorded.statuses).toEqual([{ id: "row-1", status: "paused", pauseReason: "idle" }]);
    expect(recorded.events).toEqual([{ source: "idle", automated: true }]);
  });

  test("a machine running an agent turn is not paused and its stretch is cleared", async () => {
    const busy = machineRow({
      providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: { providerVmId: VM, idleSince: T0 - 90 * MIN, observedAt: T0 - 5 * MIN } },
    });
    const { recorded, layer } = cronFakes([busy], () => ({ exitCode: 0, stdout: probeLine({ acpmux: { busy_sessions: 1, last_updated_at_ms: null } }) }));
    const summary = await Effect.runPromise(enforceVmIdlePause({ now: () => T0 }).pipe(Effect.provide(layer)));
    expect(summary).toMatchObject({ checked: 1, paused: 0, active: 1 });
    expect(recorded.paused).toEqual([]);
    expect(recorded.observations).toEqual([{ id: "row-1", observation: null }]);
  });

  test("a failed or garbled probe is unknown and never pauses", async () => {
    const previous = { providerVmId: VM, idleSince: T0 - 90 * MIN, observedAt: T0 - 5 * MIN };
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
      { id: "row-new", observation: { providerVmId: "fs-new", idleSince: T0, observedAt: T0 } },
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
    const observation = { providerVmId: VM, idleSince: T0, observedAt: T0 + MIN };
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

  test("a missing CPU sample on either side gives no CPU verdict", () => {
    const withCpu = { providerVmId: VM, idleSince: T0 - 30 * MIN, observedAt: T0 - 5 * MIN, cpuBusyMs: 1_000 };
    const withoutCpu = { providerVmId: VM, idleSince: T0 - 30 * MIN, observedAt: T0 - 5 * MIN };
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: withCpu, now: T0 }).pause).toBe(true);
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe({ cpuBusyMs: 9e9 }), previous: withoutCpu, now: T0 }).pause).toBe(true);
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe({ cpuBusyMs: null }), previous: withCpu, now: T0 }).pause).toBe(true);
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
    const previous = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN };
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
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN };
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

describe("no private address", () => {
  test("a row without a private address is unknown: not probed, never paused, observation cleared", async () => {
    const fresh = { providerVmId: VM, idleSince: T0 - 60 * MIN, observedAt: T0 - 5 * MIN };
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

describe("pause, resume and the idle stretch", () => {
  test("an observation from before a pause would carry; cleared, the stretch restarts", () => {
    const beforePause = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN };
    // What clearing prevents: resumed and probed within the gap, the old stretch would pause at once.
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: beforePause, now: T0 + 5 * MIN }).pause).toBe(true);
    expect(decideVmIdlePause({ providerVmId: VM, minutes: 30, probe: idleProbe(), previous: null, now: T0 + 5 * MIN })).toEqual({
      pause: false, reason: "idle", observation: { providerVmId: VM, idleSince: T0 + 5 * MIN, observedAt: T0 + 5 * MIN },
    });
  });

  test("pause, resume, then an idle probe: not paused again until a full timeout after the resume", async () => {
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN };
    const rows = [machineRow({ providerMetadata: { networkIpv4: "10.192.0.5", cmuxIdleObservation: observation } })];
    const { recorded, layer, resume } = cronFakes(rows, () => ({ exitCode: 0, stdout: probeLine() }));
    const runAt = (now: number) => Effect.runPromise(enforceVmIdlePause({ now: () => now }).pipe(Effect.provide(layer)));
    expect(await runAt(T0)).toMatchObject({ paused: 1 });
    expect(rows[0].status).toBe("paused");
    expect(rows[0].providerMetadata).toEqual({ networkIpv4: "10.192.0.5", cmuxPauseReason: "idle" });
    // Opened a minute later; the next runs see an idle machine.
    resume("row-1", T0 + MIN);
    expect(await runAt(T0 + 5 * MIN)).toMatchObject({ paused: 0, idle: 1 });
    expect(rows[0].providerMetadata.cmuxIdleObservation).toEqual({ providerVmId: VM, idleSince: T0 + 5 * MIN, observedAt: T0 + 5 * MIN });
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
    const observation = { providerVmId: VM, idleSince: T0 - 31 * MIN, observedAt: T0 - 5 * MIN };
    const rereads: Array<(row: CloudVmRow) => CloudVmRow | null> = [
      // An attach or a resume moved updatedAt.
      (row) => ({ ...row, updatedAt: new Date(row.updatedAt.getTime() + 1) }),
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
      expect(summary).toMatchObject({ checked: 1, paused: 0, active: 1, errors: 0 });
      expect(recorded.paused).toEqual([]);
      expect(recorded.observations).toEqual([{ id: "row-1", observation: null }]);
    }
  });
});

const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;

describe("idle pause SQL", () => {
  const owner = `idle-test-${randomUUID()}`;
  const rowId = randomUUID();
  const otherId = randomUUID();
  const providerVmId = `fs-idle-${rowId}`;
  let sql: Sql;

  beforeAll(async () => {
    if (!dbEnabled) return;
    sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 2 });
    await sql`insert into cloud_vms (id, user_id, billing_team_id, provider, provider_vm_id, image_id, status, provider_metadata)
      values (${rowId}, ${owner}, ${owner}, 'freestyle', ${providerVmId}, 'sh-test', 'running', '{"networkIpv4":"10.192.0.5"}'::jsonb),
             (${otherId}, ${owner}, ${owner}, 'freestyle', ${`fs-idle-${otherId}`}, 'sh-test', 'running', '{"cmuxIdleProbedAt":"junk"}'::jsonb)`;
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
    expect(await run(repo.recordIdleObservation!({ id: rowId, providerVmId, observation, probedAt: T0 }))).toBe(true);
    expect(await run(repo.recordVmApiActivity!({ id: rowId, providerVmId, at: T0 }))).toBe(true);
    // Within a minute of the stored time: skipped.
    expect(await run(repo.recordVmApiActivity!({ id: rowId, providerVmId, at: T0 + 30_000 }))).toBe(false);
    let row = await read();
    expect(row.metadata).toEqual({ networkIpv4: "10.192.0.5", cmuxIdleObservation: observation, cmuxIdleProbedAt: T0, cmuxLastApiActivityAt: T0 });
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
    expect(await run(repo.recordIdleObservation!({ id: rowId, providerVmId, observation, probedAt: T0 + MIN }))).toBe(true);
    expect(await run(repo.markProviderObservedStatus({ id: rowId, providerVmId, status: "running" }))).toBe(true);
    row = await read();
    expect(row.metadata.cmuxIdleObservation).toBeUndefined();
    expect(row.metadata.cmuxPauseReason).toBeUndefined();
    expect(row.metadata).toMatchObject({ networkIpv4: "10.192.0.5", cmuxIdleProbedAt: T0 + MIN, cmuxLastApiActivityAt: T0 });
  });
});
