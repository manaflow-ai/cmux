import { describe, expect, test } from "bun:test";
import type { CloudVmAttemptRef, CloudVmPreparedAttempt, CloudVmRunEvent } from "../services/vms/cloudVmRunAdapter";
import type { SandboxRunOutcome } from "../services/runs/model";
import { OutputTail, runSandboxAttempt, sandboxJournalKind, sandboxJournalPayload, type SandboxLauncherPorts } from "../services/runs/sandboxLauncher";

// A sandboxed Run (hq#3367) destroys its VM on every exit path. These drive the launcher
// through fake ports, so each path is pinned without a provider or a database.

type Calls = {
  steps: string[];
  failures: string[];
  outcomes: SandboxRunOutcome[];
};

const attemptRef = {
  provider: "cloud-vm",
  vmId: "vm-1",
  runId: "run-1",
  attemptId: "attempt-1",
  index: 0,
  workspaceId: "ws-1",
  terminalId: "term-1",
  workspaceKey: "wk",
  terminalKey: "tk",
  lease: { leaseId: "lease", leaseEpoch: 1 },
  replayed: false,
} as CloudVmAttemptRef;

function output(text: string, seq: number): CloudVmRunEvent {
  return { kind: "output", eventId: `out-${seq}`, seq, payload: { text, startOffset: 0, nextOffset: text.length } };
}

function state(status: "succeeded" | "failed" | "cancelled", exitCode?: number): CloudVmRunEvent {
  return { kind: "state", eventId: `state-${status}`, seq: 1_000, payload: { terminalId: "term-1", status, ...(exitCode === undefined ? {} : { exitCode }) } };
}

function ports(options: {
  events?: (signal: AbortSignal) => AsyncIterable<CloudVmRunEvent>;
  createVmAfterMs?: number;
  recordStartedHangs?: boolean;
  closeTerminalHangs?: boolean;
  createVmFails?: boolean;
  createVmHangs?: boolean;
  startFails?: boolean;
  ingestFailsOn?: (event: CloudVmRunEvent) => boolean;
  recordFailureFails?: boolean;
  scheduleCleanupFails?: boolean;
  destroyFails?: boolean;
} = {}): { calls: Calls; ports: SandboxLauncherPorts } {
  const calls: Calls = { steps: [], failures: [], outcomes: [] };
  const lease = { leaseToken: "lease", leaseGeneration: 1 };
  return {
    calls,
    ports: {
      claimLease: async () => {
        calls.steps.push("lease");
        return lease;
      },
      createVm: async () => {
        calls.steps.push("createVm");
        if (options.createVmFails) throw new Error("provider refused");
        if (options.createVmHangs) return new Promise<never>(() => undefined);
        if (options.createVmAfterMs !== undefined) {
          await new Promise((resolve) => setTimeout(resolve, options.createVmAfterMs));
          calls.steps.push("createVm:late");
        }
        return { providerVmId: "vm-1" };
      },
      recordStarted: async () => {
        if (options.recordStartedHangs) return new Promise<never>(() => undefined);
        calls.steps.push("started");
      },
      prepare: async (spec) => {
        calls.steps.push(`prepare:${spec.agent}:${spec.prompt}`);
        return { ...spec, provider: "cloud-vm" } as unknown as CloudVmPreparedAttempt;
      },
      start: async () => {
        calls.steps.push("start");
        if (options.startFails) throw new Error("workspace create failed");
        return attemptRef;
      },
      recordHandles: async () => {
        calls.steps.push("handles");
      },
      events: options.events ? (_attempt, signal) => options.events!(signal) : (async function* () {
        yield output("hello from ws-1\n", 1);
        yield state("succeeded", 0);
      }),
      ingest: async (_lease, event) => {
        if (options.ingestFailsOn?.(event)) throw new Error("stale or expired attempt lease");
        calls.steps.push(`ingest:${event.kind}`);
      },
      closeTerminal: async () => {
        calls.steps.push("closeTerminal");
        if (options.closeTerminalHangs) return new Promise<never>(() => undefined);
      },
      recordFailure: async (_lease, error) => {
        if (options.recordFailureFails) throw new Error("stale or expired attempt lease");
        calls.failures.push(error);
      },
      scheduleCleanup: async (_lease, providerVmId) => {
        calls.steps.push(`scheduleCleanup:${providerVmId}`);
        if (options.scheduleCleanupFails) throw new Error("stale or expired attempt lease");
      },
      destroyNow: async () => {
        calls.steps.push("destroy");
        if (options.destroyFails) throw new Error("provider destroy failed");
      },
      recordOutcome: async (_lease, outcome) => {
        calls.steps.push("outcome");
        calls.outcomes.push(outcome);
      },
      now: () => Date.now(),
      log: () => undefined,
    },
  };
}

const input = { runId: "run-1", attemptId: "attempt-1", task: "say hello", agent: "claude" as const, timeoutMs: 60_000, drainMs: 100, lateCreateWaitMs: 1_000, teardownStepMs: 200 };

describe("sandbox run lifecycle", () => {
  test("success: runs the task, hands the VM to the reaper, destroys it, records the outcome", async () => {
    const { calls, ports: p } = ports();
    await runSandboxAttempt(input, p);
    expect(calls.steps).toEqual([
      "lease", "createVm", "started", "prepare:claude:say hello", "start", "handles",
      "ingest:output", "ingest:state", "outcome", "scheduleCleanup:vm-1", "destroy",
    ]);
    expect(calls.failures).toEqual([]);
    expect(calls.outcomes).toHaveLength(1);
    // The reply never names the attempt's own provider handles.
    expect(calls.outcomes[0]).toMatchObject({ reply: "hello from [redacted]", exitCode: 0, timedOut: false });
    expect(calls.outcomes[0]?.bootMs).toBeGreaterThanOrEqual(0);
  });

  test("failure after the VM exists: records the failure and still destroys the VM", async () => {
    const { calls, ports: p } = ports({ startFails: true });
    await runSandboxAttempt(input, p);
    expect(calls.failures).toEqual(["workspace create failed"]);
    expect(calls.steps.slice(-2)).toEqual(["scheduleCleanup:vm-1", "destroy"]);
    expect(calls.outcomes).toHaveLength(1);
  });

  test("runtime bookkeeping that hangs or fails is bounded and logged, and the run goes on", async () => {
    for (const recordRuntime of [() => new Promise<never>(() => undefined), async () => { throw new Error("runtime insert failed"); }]) {
      const { calls, ports: p } = ports();
      const logged: string[] = [];
      await runSandboxAttempt(input, { ...p, recordRuntime, log: (message) => logged.push(message) });
      expect(logged).toContain("[runs] sandbox runtime bookkeeping failed");
      expect(calls.steps).toContain("createVm");
      expect(calls.steps.slice(-2)).toEqual(["scheduleCleanup:vm-1", "destroy"]);
      expect(calls.outcomes[0]?.exitCode).toBe(0);
    }
  });

  test("failure before a VM exists: nothing to hand off, the destroy pass still runs", async () => {
    const { calls, ports: p } = ports({ createVmFails: true });
    await runSandboxAttempt(input, p);
    expect(calls.failures).toEqual(["provider refused"]);
    expect(calls.outcomes[0]).toMatchObject({ error: "provider refused" });
    expect(calls.steps).not.toContain("scheduleCleanup:vm-1");
    expect(calls.steps.at(-1)).toBe("destroy");
    expect(calls.outcomes[0]).toMatchObject({ bootMs: null });
  });

  test("timeout: a quiet agent is stopped at the deadline, its terminal closed, its VM destroyed", async () => {
    const { calls, ports: p } = ports({
      // Never yields: the adapter stream stays inside its long-poll while the agent is quiet.
      events: () => ({ [Symbol.asyncIterator]: () => ({ next: () => new Promise<IteratorResult<CloudVmRunEvent>>(() => undefined) }) }),
    });
    const startedAt = Date.now();
    await runSandboxAttempt({ ...input, timeoutMs: 50 }, p);
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(calls.steps).toContain("closeTerminal");
    expect(calls.failures).toEqual(["sandbox run timed out after 0 s"]);
    expect(calls.steps.slice(-2)).toEqual(["scheduleCleanup:vm-1", "destroy"]);
    expect(calls.outcomes[0]).toMatchObject({ timedOut: true });
  });

  test("cancel: a fenced lease stops the loop; the cancel already made the VM due, the destroy still runs", async () => {
    const { calls, ports: p } = ports({
      events: async function* () {
        yield output("working", 1);
        yield state("cancelled");
      },
      ingestFailsOn: (event) => event.kind === "state",
      recordFailureFails: true,
      scheduleCleanupFails: true,
    });
    await runSandboxAttempt(input, p);
    expect(calls.steps.slice(-2)).toEqual(["scheduleCleanup:vm-1", "destroy"]);
    expect(calls.outcomes[0]).toMatchObject({ reply: "working", timedOut: false });
  });

  test("the deadline covers boot: a hung create stops at it and the destroy pass still runs", async () => {
    const { calls, ports: p } = ports({ createVmHangs: true });
    const startedAt = Date.now();
    await runSandboxAttempt({ ...input, timeoutMs: 50 }, p);
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(calls.failures).toEqual(["sandbox run timed out after 0 s"]);
    expect(calls.steps).not.toContain("started");
    expect(calls.steps.at(-1)).toBe("destroy");
    expect(calls.outcomes[0]).toMatchObject({ timedOut: true, bootMs: null });
  });

  test("a write that hangs after boot stops at the deadline, and the VM is still handed off and destroyed", async () => {
    const { calls, ports: p } = ports({ recordStartedHangs: true });
    const startedAt = Date.now();
    await runSandboxAttempt({ ...input, timeoutMs: 50 }, p);
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(calls.steps.slice(-3)).toEqual(["outcome", "scheduleCleanup:vm-1", "destroy"]);
    expect(calls.outcomes[0]).toMatchObject({ timedOut: true, error: "sandbox run timed out after 0 s" });
  });

  test("the deadline counts from the request, so time spent before the launch comes off the task", async () => {
    const { calls, ports: p } = ports({ events: () => ({ [Symbol.asyncIterator]: () => ({ next: () => new Promise<IteratorResult<CloudVmRunEvent>>(() => undefined) }) }) });
    const startedAt = Date.now();
    await runSandboxAttempt({ ...input, timeoutMs: 60_000, requestedAt: Date.now() - 59_950 }, p);
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(calls.outcomes[0]).toMatchObject({ timedOut: true });
  });

  test("a terminal close that hangs at the timeout is abandoned, and teardown still runs", async () => {
    const quiet = () => ({ [Symbol.asyncIterator]: () => ({ next: () => new Promise<IteratorResult<CloudVmRunEvent>>(() => undefined) }) });
    const { calls, ports: p } = ports({ closeTerminalHangs: true, events: quiet });
    const startedAt = Date.now();
    await runSandboxAttempt({ ...input, timeoutMs: 50 }, p);
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(calls.steps.slice(-3)).toEqual(["outcome", "scheduleCleanup:vm-1", "destroy"]);
  });

  test("a launch whose budget is already spent creates no VM", async () => {
    const { calls, ports: p } = ports();
    await runSandboxAttempt({ ...input, timeoutMs: 1_000, requestedAt: Date.now() - 5_000 }, p);
    expect(calls.steps).not.toContain("createVm");
    expect(calls.outcomes[0]).toMatchObject({ timedOut: true });
  });

  test("runtime bookkeeping that runs into the deadline creates no VM", async () => {
    const { calls, ports: p } = ports();
    const recordRuntime = () => new Promise<void>((resolve) => setTimeout(resolve, 400));
    await runSandboxAttempt({ ...input, timeoutMs: 1_000, requestedAt: Date.now() - 800, teardownStepMs: 5_000 }, { ...p, recordRuntime });
    expect(calls.steps).not.toContain("createVm");
    expect(calls.outcomes[0]).toMatchObject({ timedOut: true });
  });

  test("a create the deadline abandoned is still handed to the reaper when it finishes", async () => {
    const { calls, ports: p } = ports({ createVmAfterMs: 200 });
    await runSandboxAttempt({ ...input, timeoutMs: 50 }, p);
    expect(calls.failures).toEqual(["sandbox run timed out after 0 s"]);
    expect(calls.steps.slice(-4)).toEqual(["createVm:late", "outcome", "scheduleCleanup:vm-1", "destroy"]);
  });

  test("output the terminal state raced is still read; the stream stops once the launcher returns", async () => {
    let stopped: AbortSignal | undefined;
    const { calls, ports: p } = ports({
      events: async function* (signal) {
        stopped = signal;
        yield state("succeeded", 0);
        yield output("the answer\n", 2);
      },
    });
    await runSandboxAttempt(input, p);
    expect(calls.outcomes[0]).toMatchObject({ reply: "the answer", exitCode: 0 });
    // The terminal event ended the lease: the drained output is in the reply, not the journal.
    expect(calls.steps.filter((step) => step.startsWith("ingest:"))).toEqual(["ingest:state"]);
    expect(stopped?.aborted).toBe(true);
  });

  test("the tail is redacted whole, so chunking, eviction and long lines never separate a secret from its context", async () => {
    const tail = (chunks: string[]) => {
      const kept = new OutputTail();
      for (const chunk of chunks) kept.append(chunk);
      return kept.toString();
    };
    expect(tail(["short"])).toBe("short");
    // A line longer than the window is dropped through its newline, across chunks.
    expect(tail([`ghp_${"a".repeat(36)}${"x".repeat(70_000)}\nlast line`])).toBe("[long line omitted]\nlast line");
    const split = tail(["x".repeat(32_768), "x".repeat(32_768), " password=", "example-pass-123!\n", "after\n"]);
    expect(split).toBe("[long line omitted]\nafter\n");
    // Long runs of spaces collapse, so a line of them is kept and its token still redacted.
    expect(tail([`ghp_${"a".repeat(36)}${" ".repeat(70_000)}\nlast line`])).toBe("[redacted] \nlast line");
    // Cut off mid-line by a timeout: the unfinished line is redacted too.
    expect(tail(['echo PASSWORD="example-pass-123!'])).not.toContain("example-pass-123!");
  });

  test("a label and its value are redacted together: next line, quoted across lines, past blank output or a long line", () => {
    const tail = (chunks: string[]) => {
      const kept = new OutputTail();
      for (const chunk of chunks) kept.append(chunk);
      return kept.toString();
    };
    expect(tail(["PASSWORD:\n", "hunter2\n", "after\n"])).toBe("PASSWORD:\n[redacted]\nafter\n");
    expect(tail(['PASSWORD="\n', "  hunter2\n", '"\n', "after\n"])).not.toContain("hunter2");
    // Any amount of blank lines or spaces between them collapses.
    expect(tail(["export API_KEY=\n", "\n".repeat(70_000), "hunter2\n", "after\n"])).not.toContain("hunter2");
    expect(tail([" ".repeat(70_000), "PASSWORD:\nhunter2\n"])).not.toContain("hunter2");
    // The whole-text grammar: suffixed names and signature labels too.
    expect(tail(["PASSWORD_PROD:\n", "\n".repeat(70_000), "hunter2\n"])).not.toContain("hunter2");
    expect(tail(["SharedAccessSignature:\n", "c2lnbmF0dXJlMTIz\n"])).not.toContain("c2lnbmF0dXJlMTIz");
    // A label at the end of a line too long to keep stands in for it, open quote included.
    expect(tail(["x".repeat(70_000), " PASSWORD:\n", "hunter2\n", "after\n"])).toBe("[long line omitted] secret=\n[redacted]\nafter\n");
    expect(tail(["x".repeat(70_000), ' PASSWORD="\n', "  hunter2\n", '"\n'])).not.toContain("hunter2");
    // A long line that opens a quoted value at its start, with no close near its end, stays open.
    expect(tail([`PASSWORD="${"t".repeat(70_000)}`, "\nhunter2\n", '"\n'])).not.toContain("hunter2");
    // An open quote whose label scrolls out of the window still covers its value.
    expect(tail(['PASSWORD="\n', "x\n".repeat(70_000), 'hunter2\n"\n', "after\n"])).not.toContain("hunter2");
    // A label whose line scrolls out just before its value still covers it.
    expect(tail(["y\n".repeat(32_767), "PASSWORD:\n", "hunter2\n", "z\n".repeat(40_000)])).not.toContain("hunter2");
    // The stand-in keeps the opening quote, not the last quote character inside the value.
    expect(tail([`PASSWORD="it's ${"t".repeat(70_000)}`, "\nfoo'\n", "hunter2\n", '"\n'])).not.toContain("hunter2");
    // Only the opening quote's own character closes it: an apostrophe near the end does not.
    expect(tail([`PASSWORD="${"t".repeat(70_000)}it's`, "\nhunter2\n", '"\n'])).not.toContain("hunter2");
    // Progress output that rewrites its line, then a secret: the carriage return is a boundary.
    expect(tail(["loading\rsk-abcdefghijklmnopqrstuvwxyz\n"])).not.toContain("abcdefghijklmnop");
    expect(tail(["db:\n  password: |-\n", "    hunter2\n", "  host: x\n"])).not.toContain("hunter2");
    // Cookie headers, a bare signature and a YAML block whose header carries a comment.
    expect(tail(["Set-Cookie: session=abc123def; Path=/\n", "after\n"])).not.toContain("abc123def");
    expect(tail(["signature: c2lnbmF0dXJlMTIz\n"])).not.toContain("c2lnbmF0dXJlMTIz");
    expect(tail(["password: |- # rotated\n", "  hunter2\n", "host: x\n"])).not.toContain("hunter2");
    // A long line that ends in a whole value stands in for nothing: the next line is kept.
    expect(tail(["x".repeat(70_000), " password=done\n", "after\n"])).toBe("[long line omitted]\nafter\n");
  });

  test("a private key never survives: evicted header, long lines, escapes, a hidden header, no final newline", async () => {
    const tail = (chunks: string[]) => {
      const kept = new OutputTail();
      for (const chunk of chunks) kept.append(chunk);
      return kept.toString();
    };
    const { generateKeyPairSync } = await import("node:crypto");
    const pem = generateKeyPairSync("ed25519").privateKey.export({ format: "pem", type: "pkcs8" }).toString();
    const body = pem.split("\n").slice(1, -2).join("\n");
    expect(tail([pem, `${"pad\n".repeat(20_000)}`, "done\n"])).not.toContain(body);
    expect(tail(["log\n", pem, "done\n"])).toBe("log\n[redacted private key]\ndone\n");
    // Terminal escapes inside the markers can't hide the block.
    const escaped = pem.replace("-----BEGIN PRIVATE KEY-----", "-----BEGIN \u001b[0mPRIVATE KEY-----").replace("-----END PRIVATE KEY-----", "-----END \u001b[1mPRIVATE KEY-----");
    expect(tail(["log\n", escaped, "done\n"])).toBe("log\n[redacted private key]\ndone\n");
    // A key straight after a line too long to keep: the dropped line's BEGIN marker still starts
    // the block, also when the marker itself is split across chunks.
    const pad = "A".repeat(35_000);
    expect(tail([pad, pad, pem, "done\n"])).toBe("[redacted private key]\ndone\n");
    const cut = pem.indexOf("PRIVATE");
    expect(tail([pad, pad, pem.slice(0, cut), pem.slice(cut), "done\n"])).toBe("[redacted private key]\ndone\n");
    // A marker split by a long run of escapes, and an escape split across chunks, still count.
    const escapedPem = pem.replace("-----BEGIN PRIVATE KEY-----", `-----BEGIN ${"\u001b[0m".repeat(200)}PRIVATE KEY-----`);
    const escapeCut = escapedPem.indexOf("\u001b[0m") + 2;
    expect(tail([pad, pad, escapedPem.slice(0, 600), escapedPem.slice(600), "done\n"])).toBe("[redacted private key]\ndone\n");
    expect(tail([pad, pad, escapedPem.slice(0, escapeCut), escapedPem.slice(escapeCut), "done\n"])).toBe("[redacted private key]\ndone\n");
    // An OSC sequence swallows text, newlines included, until its BEL: a marker split by one
    // across lines reads whole, and a header an OSC hid still takes the body with it.
    const oscSplit = pem.replace("-----BEGIN PRIVATE KEY-----", "-----BEGIN PRIV\u001b]0;title\n\u0007ATE KEY-----");
    expect(tail(["log\n", oscSplit, "done\n"])).toBe("log\n[redacted private key]\ndone\n");
    const hiddenHeader = pem.replace("-----BEGIN PRIVATE KEY-----\n", "-----BEGIN \u001b]0;PRIVATE KEY-----\n\u0007");
    expect(tail(["log\n", hiddenHeader, "done\n"])).toBe("log\n[redacted private key]\ndone\n");
    // The output ends right after the END marker, with no newline.
    const noNewline = hiddenHeader.trimEnd();
    expect(tail(["log\n", noNewline])).toBe("log\n[redacted private key]");
    // An END on a line too long to keep, and a body line too long to keep, still take the body back.
    const longEnd = hiddenHeader.replace("-----END PRIVATE KEY-----", `-----END PRIVATE KEY-----${" x".repeat(40_000)}`);
    const longEndOut = tail(["log\n", longEnd, "done\n"]);
    expect(longEndOut).not.toContain(body);
    expect(longEndOut).toBe("log\n[redacted private key]\ndone\n");
    const longBody = hiddenHeader.replace("\u0007", `\u0007${"Q".repeat(70_000)}\n`);
    expect(tail(["log\n", longBody, "done\n"])).toBe("log\n[redacted private key]\ndone\n");
    // A body whose last line is short is taken back whole.
    const shortTail = "-----BEGIN \u001b]0;PRIVATE KEY-----\n\u0007" + `${"Q".repeat(64)}\nAB==\n-----END PRIVATE KEY-----\n`;
    expect(tail(["log\n", shortTail, "done\n"])).toBe("log\n[redacted private key]\ndone\n");
  });

  test("a sandbox journals its states, never its raw terminal output", () => {
    expect(sandboxJournalKind(output("-----BEGIN PRIVATE KEY-----\n", 1))).toBeNull();
    expect(sandboxJournalKind({ kind: "state", eventId: "state-running", seq: 2, payload: { terminalId: "term-1", status: "running" } })).toBe("attempt.started");
    expect(sandboxJournalKind(state("succeeded", 0))).toBe("attempt.succeeded");
    expect(sandboxJournalKind(state("failed", 1))).toBe("attempt.failed");
    expect(sandboxJournalKind(state("cancelled"))).toBe("attempt.failed");
    // The adapter's terminal id is a provider handle: the journal keeps only the state.
    expect(sandboxJournalPayload({ kind: "state", eventId: "state-running", seq: 2, payload: { terminalId: "term-1", status: "running" } })).toEqual({ status: "running" });
    expect(sandboxJournalPayload({ kind: "state", eventId: "state-done", seq: 3, payload: { terminalId: "term-1", status: "failed", exitCode: 2 } })).toEqual({ status: "failed", exitCode: 2 });
  });

  test("a YAML secret block stays redacted after its header drops off the window, and past a long line", () => {
    const read = (text: string) => {
      const kept = new OutputTail();
      for (let at = 0; at < text.length; at += 30_000) kept.append(text.slice(at, at + 30_000));
      return kept.toString();
    };
    expect(read(`password: |-\n${"  padding text\n".repeat(10_000)}  hunter2-secret\n`)).not.toContain("hunter2-secret");
    expect(read(`password: |-\n  ${"x".repeat(70_000)}\n  hunter2-secret\n`)).not.toContain("hunter2-secret");
    // At any indent, however deep (a long indent is kept, not collapsed).
    for (const [header, body] of [[48, 50], [70, 72]] as const) {
      const pad = (n: number) => " ".repeat(n);
      expect(read(`${pad(header)}password: |-\n${`${pad(body)}padding text\n`.repeat(3_000)}${pad(body)}hunter2-secret\n`)).not.toContain("hunter2-secret");
    }
    // Past the indent bound (a header and its value both deeper than it), with no eviction at all.
    expect(read(`${" ".repeat(1_024)}password: |-\n${" ".repeat(1_026)}hunter2-secret\n`)).not.toContain("hunter2-secret");
    expect(read(`${" ".repeat(2_000)}password: |-\n${" ".repeat(2_002)}hunter2-secret\n`)).not.toContain("hunter2-secret");
    // A long line inside a deep block keeps the block's depth, so the value after it is still in it.
    expect(read(`${" ".repeat(256)}password: |-\n${" ".repeat(258)}${"x".repeat(70_000)}\n${" ".repeat(258)}hunter2-secret\n`)).not.toContain("hunter2-secret");
    // CRLF line ends: the header is still read as one when its indent is cut.
    expect(read(`${" ".repeat(1_024)}password: |-\r\n${" ".repeat(1_026)}hunter2-secret\r\n`)).not.toContain("hunter2-secret");
    // A deep header that is itself too long to keep (a long comment) still opens its block.
    expect(read(`${" ".repeat(1_000)}password: |- #${"c".repeat(70_000)}\n${" ".repeat(1_002)}hunter2-secret\n`)).not.toContain("hunter2-secret");
    // A block under a key that is not a secret's stays readable.
    expect(read(`notes: |-\n${"  padding text\n".repeat(10_000)}  visible-line\n`)).toContain("visible-line");
  });

  test("a failure is redacted whole before it is cut to 500 characters", async () => {
    const message = `${"e".repeat(470)} password="example-pass-123!"`;
    const { calls, ports: p } = ports();
    await runSandboxAttempt(input, { ...p, createVm: async () => { throw new Error(message); } });
    expect(calls.failures[0]).not.toContain("example-pass-123!");
    expect(calls.failures[0]!.length).toBeLessThanOrEqual(500);
  });

  test("the first terminal state ends the loop without waiting for the stream to drain", async () => {
    const { calls, ports: p } = ports({
      events: () => {
        let sent = false;
        return {
          [Symbol.asyncIterator]: () => ({
            next: () => {
              if (sent) return new Promise<IteratorResult<CloudVmRunEvent>>(() => undefined);
              sent = true;
              return Promise.resolve({ done: false, value: state("succeeded", 0) });
            },
          }),
        };
      },
    });
    const startedAt = Date.now();
    await runSandboxAttempt({ ...input, timeoutMs: 60_000 }, p);
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(calls.failures).toEqual([]);
    expect(calls.outcomes[0]).toMatchObject({ exitCode: 0, timedOut: false });
  });

  test("a failed inline destroy is left to the reaper and the outcome is still recorded", async () => {
    const { calls, ports: p } = ports({ destroyFails: true });
    await runSandboxAttempt(input, p);
    expect(calls.steps).toContain("destroy");
    expect(calls.outcomes).toHaveLength(1);
  });
});
