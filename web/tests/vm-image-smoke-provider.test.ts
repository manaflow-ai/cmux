import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  bootDiagRow,
  classifyGuestWait,
  cloneTrace,
  cpuDelta,
  daemonListening,
  diagSections,
  imageLatency,
  LISTEN_POLL,
  measureCloneRetrying,
  parseBindTrace,
  parseListenWindow,
  providerLatency,
  providerStall,
  ProviderUnfinished,
  rowForLog,
} from "../scripts/cmux-vm-image/smoke";
import type { Vm } from "../scripts/cmux-vm-image/guest";

const clone = (vmId: string) => ({ vm: {} as Vm, vmId, name: `cmuxnp-dev-vmimg-t-smoke-${vmId}` });
const row = (createApiMs: number, listening: number, ready: number) => ({ vmId: "vm", createApiMs, createDoneToListeningMs: listening, createDoneToReadyMs: ready });

describe("smoke daemon-listening judges the image, not the provider", () => {
  test("a slow create call does not fail the check", () => {
    // Roll 43953739384: createApi raw 40323/7132/25760/4371/2866 ms.
    const rows = [row(40323, 900, 1200), row(7132, 800, 1100), row(25760, 950, 1300), row(4371, 700, 1000), row(2866, 750, 1050)];
    expect(daemonListening(rows)).toBe(true);
    expect((providerLatency(rows, []).createApi as { p95: number }).p95).toBe(40323);
    expect(imageLatency(rows)).not.toHaveProperty("createApi");
  });

  test("a daemon that never listened on a finished clone fails it", () => {
    expect(daemonListening([row(500, 900, 1200), row(500, -1, -1)])).toBe(false);
    expect(daemonListening([row(500, 900, -1)])).toBe(false);
    expect(daemonListening([])).toBe(false);
  });
});

describe("providerStall", () => {
  test("roll 43953739384 clone 3: a guest stalled 13.8 s before its first exec is the provider's", () => {
    expect(providerStall(25760, 39606, 1)).toContain("first exec 13846 ms after the create returned");
  });

  test("a guest that answered promptly and has no daemon is the image's", () => {
    expect(providerStall(4371, 5037, 1)).toBeUndefined();
  });

  test("a listening daemon is never a stall", () => {
    expect(providerStall(25760, 39606, 0)).toBeUndefined();
  });
});

describe("measureCloneRetrying", () => {
  test("replaces a clone the provider never finished and deletes it", async () => {
    const deleted: string[] = [];
    const budget = { left: 3, unfinished: [] as string[] };
    const result = await measureCloneRetrying(
      async (attempt) => {
        if (attempt === 0) throw new ProviderUnfinished(clone("vm-a"), "first exec: guest never answered an exec");
        return { clone: clone("vm-b"), row: row(500, 900, 1200) };
      },
      async (c) => void deleted.push(c.vmId),
      budget,
      0,
    );
    expect(result.clone.vmId).toBe("vm-b");
    expect(deleted).toEqual(["vm-a"]);
    expect(budget).toEqual({ left: 2, unfinished: ["first exec: guest never answered an exec"] });
  });

  test("a failed create has no clone to delete", async () => {
    const deleted: string[] = [];
    const budget = { left: 1, unfinished: [] as string[] };
    await measureCloneRetrying(
      async (attempt) => {
        if (attempt === 0) throw new ProviderUnfinished(undefined, "create: 429");
        return { clone: clone("vm-b"), row: row(500, 900, 1200) };
      },
      async (c) => void deleted.push(c.vmId),
      budget,
      0,
    );
    expect(deleted).toEqual([]);
  });

  test("stops at the budget, naming the provider", async () => {
    const budget = { left: 1, unfinished: [] as string[] };
    const run = measureCloneRetrying(async () => { throw new ProviderUnfinished(clone("vm-x"), "create: 500"); }, async () => {}, budget, 0);
    await expect(run).rejects.toThrow("provider never finished 2 clones: create: 500; create: 500");
  });

  test("never retries an image failure", async () => {
    let calls = 0;
    const budget = { left: 3, unfinished: [] as string[] };
    const run = measureCloneRetrying(async () => { calls++; throw new Error("image broke"); }, async () => {}, budget, 0);
    await expect(run).rejects.toThrow("image broke");
    expect(calls).toBe(1);
    expect(budget.left).toBe(3);
  });
});

describe("the listen poll", () => {
  test("sleeps between checks instead of spinning on the clone's CPU", () => {
    expect(LISTEN_POLL).toMatch(/until grep [^;]*; do [\s\S]*sleep 0\.05; done/);
  });

  test("prints its uptime window and CPU counters around the wait", () => {
    // A port nothing listens on: the poll's own shell, run here with a 1 s budget.
    const poll = LISTEN_POLL.replace("-gt 30000", "-gt 1000");
    const r = spawnSync("sh", ["-c", poll], { encoding: "utf8" });
    const window = parseListenWindow(r.stdout);
    expect(/guest-wait-ms (\d+)/.exec(r.stdout)?.[1]).toBeDefined();
    expect(window?.endS).toBeGreaterThanOrEqual(window?.startS ?? Number.POSITIVE_INFINITY);
    expect(window?.stealMs).toBeGreaterThanOrEqual(0);
    // About 20 checks a second, not thousands: the loop's own CPU stays far below the wait.
    expect(window?.busyMs ?? 0).toBeLessThan(5_000);
  });
});

// A clone whose trace carries the source's lines, then its resume, three metadata reads and a slow flock.
const TRACE = [
  "900.00 boot-start pid=411",
  "905.10 start-daemon",
  "905.12 daemon-forked ms=20 pid=500",
  "1000.00 resumed gap_ms=86400000",
  "1000.05 metadata-first result=empty ms=40",
  "1002.20 metadata-ok attempts=3 ms=30",
  "1002.21 kind-flock acquired wait_ms=8000",
  "1010.25 kind-reset ms=8040 locked=1",
  "1010.30 start-daemon",
  "1010.32 daemon-forked ms=20 pid=812",
].join("\n");
const LISTEN = [
  "listen-start-uptime 1000.40",
  "stat-start cpu 100 0 50 1000 5 0 1 10 0 0",
  "guest-wait-ms 10210",
  "listen-end-uptime 1010.61",
  "stat-end cpu 600 0 150 2500 5 0 3 130 0 0",
  "psi-cpu some avg10=41.00 avg60=12.00 avg300=3.00 total=9000000",
].join("\n");
const DIAG = `--- bind-trace\n${TRACE}\n--- uptime\n1030.00 1900.00\n--- stat\ncpu 900 0 200 4000 5 0 3 140 0 0\n--- pressure-cpu\nsome avg10=1.00 avg60=9.00 avg300=3.00 total=9100000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n--- journal\n[ 1010.320000] host cmux-devbox-boot[411]: started\n`;

describe("bind trace parsing", () => {
  test("keeps only the clone's own lines, from its resume", () => {
    const own = cloneTrace(parseBindTrace(TRACE));
    expect(own[0]).toEqual({ t: 1000, event: "resumed", fields: { gap_ms: "86400000" } });
    expect(own.map((e) => e.event)).toEqual(["resumed", "metadata-first", "metadata-ok", "kind-flock", "kind-reset", "start-daemon", "daemon-forked"]);
  });

  test("without a resume line the clone starts at its first metadata read", () => {
    const own = cloneTrace(parseBindTrace(TRACE.split("\n").filter((l) => !l.includes("resumed")).join("\n")));
    expect(own[0].event).toBe("metadata-first");
  });

  test("skips junk lines", () => {
    expect(parseBindTrace("garbage\n\n12.5\nx boot-start\n12.50 boot-start pid=1")).toEqual([{ t: 12.5, event: "boot-start", fields: { pid: "1" } }]);
  });

  test("splits the diagnostics exec into its sections", () => {
    const sections = diagSections(DIAG);
    expect(Object.keys(sections)).toEqual(["bind-trace", "uptime", "stat", "pressure-cpu", "journal"]);
    expect(sections.uptime).toBe("1030.00 1900.00");
  });

  test("CPU deltas are in ms at USER_HZ 100, guest time not counted twice", () => {
    expect(cpuDelta("cpu 100 0 50 1000 5 0 1 10 9 0", "cpu 600 0 150 2500 5 0 3 130 50 0")).toEqual({ stealMs: 1200, busyMs: 6020 });
    expect(cpuDelta("", "cpu 1 2 3")).toBeUndefined();
  });
});

describe("classifyGuestWait", () => {
  test("a 10 s wait spent in the vm-kind flock is named so", () => {
    const { phase, ms } = classifyGuestWait(parseBindTrace(TRACE), parseListenWindow(LISTEN));
    expect(phase).toBe("kind-flock");
    expect(ms).toEqual({ metadata: 1800, "kind-flock": 8050, "clone-branch": 50, "state-mount": 20, "daemon-listen": 290 });
  });

  test("a wait in metadata reads is named so", () => {
    const slowMetadata = TRACE.replace("1002.20 metadata-ok attempts=3", "1009.00 metadata-ok attempts=40").replace("wait_ms=8000", "wait_ms=10").replace("1010.25 kind-reset ms=8040", "1009.05 kind-reset ms=50");
    expect(classifyGuestWait(parseBindTrace(slowMetadata), parseListenWindow(LISTEN)).phase).toBe("metadata");
  });

  test("no trace or no window says no-trace; a trace without the clone's steps is unplaced", () => {
    expect(classifyGuestWait([], parseListenWindow(LISTEN)).phase).toBe("no-trace");
    expect(classifyGuestWait(parseBindTrace(TRACE), undefined).phase).toBe("no-trace");
    expect(classifyGuestWait(parseBindTrace("900.00 boot-start pid=1"), parseListenWindow(LISTEN)).phase).toBe("unplaced");
  });

  test("a wait that began before the guest resumed counts that part as before-resume", () => {
    const early = LISTEN.replace("listen-start-uptime 1000.40", "listen-start-uptime 995.00");
    expect(classifyGuestWait(parseBindTrace(TRACE), parseListenWindow(early)).ms["before-resume"]).toBe(5000);
  });
});

describe("bootDiagRow", () => {
  test("puts the phase, its split, steal, pressure, trace and journal in the clone's row", () => {
    const row = bootDiagRow(LISTEN, DIAG);
    expect(row).toMatchObject({
      guestWaitPhase: "kind-flock",
      "wait-kind-flock-ms": 8050,
      metadataAttempts: 3,
      kindFlockWaitMs: 8000,
      listenStealMs: 1200,
      listenPsiCpu: "some avg10=41.00 avg60=12.00 avg300=3.00 total=9000000",
    });
    expect(String(row.psiCpu)).toContain("full avg10=0.00");
    expect(String(row.bindTrace).split("\n")[0]).toBe("1000 resumed gap_ms=86400000");
    expect(String(row.daemonJournal)).toContain("cmux-devbox-boot[411]");
    expect(rowForLog(row)).not.toHaveProperty("daemonJournal");
    expect(rowForLog(row)).not.toHaveProperty("bindTrace");
  });

  test("an image without the trace still gets steal and pressure", () => {
    const row = bootDiagRow(LISTEN, "--- bind-trace\n--- uptime\n1.00 1.00\n--- journal\n-- No entries --\n");
    expect(row.guestWaitPhase).toBe("no-trace");
    expect(row.listenStealMs).toBe(1200);
  });
});

describe("the boot supervisor's bind trace", () => {
  const boot = readFileSync(path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-devbox-boot"), "utf8");
  const fn = (name: string) => {
    const start = boot.indexOf(`${name}() {`);
    return boot.slice(start, boot.indexOf("\n}\n", start) + 3);
  };

  test("writes every stamp the smoke classifies by", () => {
    for (const stamp of ["bind_trace boot-start", "bind_trace resumed gap_ms=", "metadata-first result=", "bind_trace metadata-ok attempts=", "bind_trace kind-reset ms=", "bind_trace start-daemon", "bind_trace daemon-forked ms="]) expect(boot).toContain(stamp);
    expect(boot).toContain('BIND_TRACE="$TEMPLATE_RUN_DIR/bind-trace"');
  });

  test("its lines parse, and a write that fails never fails the caller", () => {
    const dir = spawnSync("mktemp", ["-d"], { encoding: "utf8" }).stdout.trim();
    const script = `${fn("uptime_cs")}${fn("bind_trace")}BIND_TRACE=${dir}/run/bind-trace\nbind_trace start-daemon\nuptime_cs\necho cs=$up_cs\nBIND_TRACE=/proc/self/nope/bind-trace\nbind_trace start-daemon || echo failed\ncat ${dir}/run/bind-trace\nrm -rf ${dir}`;
    const r = spawnSync("sh", ["-c", script], { encoding: "utf8" });
    expect(r.status).toBe(0);
    expect(r.stderr).toBe("");
    expect(r.stdout).not.toContain("failed");
    expect(Number(/cs=(\d+)/.exec(r.stdout)?.[1])).toBeGreaterThan(0);
    expect(parseBindTrace(r.stdout).map((e) => e.event)).toEqual(["start-daemon"]);
  });

  test("a clone's vm-kind sync runs after its daemon start, never before its reset", () => {
    const clone = boot.indexOf('if [ -n "$id" ] && [ "$id" != "$(cat "$BOUND_INSTANCE_FILE" 2>/dev/null)" ]; then');
    const parked = boot.lastIndexOf("tick=$PARKED_TICK", clone);
    const firstSync = boot.indexOf("sync_vm_kind_if_due\n", parked);
    expect(boot.indexOf("mark_vm_kind_shared\n", clone)).toBeLessThan(firstSync);
    expect(boot.indexOf("start_daemon\n", clone)).toBeLessThan(firstSync);
  });
});
