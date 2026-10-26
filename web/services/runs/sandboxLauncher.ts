import type { CloudVmAgent, CloudVmAttemptRef, CloudVmPreparedAttempt, CloudVmRunAttemptSpec, CloudVmRunEvent } from "../vms/cloudVmRunAdapter";
import type { SandboxRunOutcome } from "./model";
import { redactReceiptText, sandboxReply } from "./sandbox";

/** Terminal output the launcher keeps in memory for the receipt's reply. */
const SANDBOX_OUTPUT_TAIL_CHARS = 64 * 1024;
/** How long the launcher reads output after the terminal state, for the last lines it raced. */
const SANDBOX_DRAIN_MS = 15_000;
/**
 * How long teardown waits for a create the deadline abandoned. Budget from the request (the
 * route's 960 s maxDuration counts from there): the deadline is the longest task (720 s), then
 * the failure record (20 s), this wait (60 s), the outcome and handoff writes (20 s each) and
 * the destroy (60 s): 900 s, leaving the lease claim and the response their share of the rest.
 */
const SANDBOX_LATE_CREATE_MS = 60_000;

/**
 * The last part of the output, kept whole lines only: a cut inside a line could split a secret
 * from the prefix (`ghp_`, `password=`) that redaction recognizes it by. Once a line is cut, the
 * rest of it is dropped too, across chunks, until its newline arrives.
 */
export class OutputTail {
  private text = "";
  private skippingLine = false;

  append(chunk: string): void {
    let next = chunk;
    if (this.skippingLine) {
      const end = next.indexOf("\n");
      if (end < 0) return;
      next = next.slice(end + 1);
      this.skippingLine = false;
    }
    const joined = this.text + next;
    if (joined.length <= SANDBOX_OUTPUT_TAIL_CHARS) {
      this.text = joined;
      return;
    }
    const cut = joined.slice(-SANDBOX_OUTPUT_TAIL_CHARS);
    const lineStart = cut.indexOf("\n");
    if (lineStart < 0) {
      // One line longer than the whole window: drop it, and whatever of it is still to come.
      this.text = "";
      this.skippingLine = true;
      return;
    }
    this.text = cut.slice(lineStart + 1);
  }

  toString(): string {
    return this.text;
  }
}

function exitOf(receipt: { readonly exitCode?: number; readonly signal?: number }, exitCode: number | null, signal: number | null) {
  return { exitCode: receipt.exitCode ?? exitCode, signal: receipt.signal ?? signal };
}

/** Each teardown write and the failure record get this long; the reaper and the sweep cover a miss. */
const SANDBOX_TEARDOWN_STEP_MS = 20_000;
/** The inline destroy (one provider call plus its DB writes). */
const SANDBOX_DESTROY_MS = 60_000;

/** `work`, abandoned (and reported as an error) once `ms` pass, so no teardown step can hang it. */
async function bounded<T>(work: Promise<T>, ms = SANDBOX_TEARDOWN_STEP_MS): Promise<T> {
  const result = await settleBefore(work, ms);
  if (result === "timeout") throw new Error(`sandbox step did not answer within ${Math.round(ms / 1000)} s`);
  return result.value;
}

class SandboxDeadlineError extends Error {
  constructor(timeoutMs: number) {
    super(`sandbox run timed out after ${Math.round(timeoutMs / 1000)} s`);
  }
}

/**
 * `work`'s result, or "timeout" once `remainingMs` passes. The adapter's stream yields only on
 * new output or a state change, so a quiet agent would otherwise never reach a deadline check.
 * The timer is cleared on every path.
 */
async function settleBefore<T>(work: Promise<T>, remainingMs: number): Promise<{ readonly value: T } | "timeout"> {
  if (remainingMs <= 0) {
    work.catch(() => undefined);
    return "timeout";
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work.then((value) => ({ value })),
      new Promise<"timeout">((resolve) => {
        timer = setTimeout(() => resolve("timeout"), remainingMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    // A step the deadline abandoned may still reject; it has nobody left to report to.
    work.catch(() => undefined);
  }
}

type Lease = { readonly leaseToken: string; readonly leaseGeneration: number };

/** Everything the launcher touches, so each exit path can be tested without a provider or DB. */
export type SandboxLauncherPorts = {
  readonly claimLease: () => Promise<Lease>;
  readonly createVm: () => Promise<{ readonly providerVmId: string }>;
  readonly recordStarted: (lease: Lease, providerVmId: string) => Promise<void>;
  readonly prepare: (spec: CloudVmRunAttemptSpec) => Promise<CloudVmPreparedAttempt>;
  readonly start: (prepared: CloudVmPreparedAttempt) => Promise<CloudVmAttemptRef>;
  readonly recordHandles: (lease: Lease, attempt: CloudVmAttemptRef) => Promise<void>;
  /** The run's events; the stream ends at its next provider call once `signal` aborts. */
  readonly events: (attempt: CloudVmAttemptRef, signal: AbortSignal) => AsyncIterable<CloudVmRunEvent>;
  /** Renews the lease and journals one event; throws once the attempt was fenced (a cancel). */
  readonly ingest: (lease: Lease, event: CloudVmRunEvent) => Promise<void>;
  readonly closeTerminal: (attempt: CloudVmAttemptRef) => Promise<void>;
  readonly recordFailure: (lease: Lease, error: string, sequence: number, providerVmId: string | undefined) => Promise<void>;
  /** Due-now retention: hands the VM to the reaper even if the inline destroy below fails. */
  readonly scheduleCleanup: (lease: Lease, providerVmId: string) => Promise<void>;
  /** Destroys this Run's due VMs through the reaper's fenced claim. */
  readonly destroyNow: () => Promise<void>;
  /** Fenced on the lease generation: a launcher a cancel or a replacement lease fenced writes nothing. */
  readonly recordOutcome: (lease: Lease, outcome: SandboxRunOutcome) => Promise<void>;
  readonly now: () => number;
  readonly log: (message: string, error: unknown) => void;
};

export type SandboxLaunchInput = {
  readonly runId: string;
  readonly attemptId: string;
  readonly task: string;
  readonly agent: CloudVmAgent;
  readonly timeoutMs: number;
  /** When the create request arrived (epoch ms): the deadline counts from it, as the route's budget does. */
  readonly requestedAt?: number;
  /** Tests shorten these; production uses the defaults above. */
  readonly drainMs?: number;
  readonly lateCreateWaitMs?: number;
  readonly teardownStepMs?: number;
};

/**
 * One sandboxed attempt: boot, run the task, journal it, then always tear down. The VM is handed
 * to the reaper with a due-now deadline before the inline destroy, so a crash after that point
 * is still cleaned up; a crash before it is found by the reaper's abandoned-sandbox sweep.
 * One deadline, from the create request, covers the lease claim, boot, setup and the task, so a hung provider call
 * can't outlive the route's budget or the lease: each step is raced against it. A VM whose create
 * finishes after the deadline is still handed to the reaper (and the sweep finds it by its create
 * key if this process dies first). The run loop stops when the stream ends after the terminal
 * state (or a short drain window after it), at the deadline, or when a cancel fences the lease.
 * On return the launcher aborts `stop`, so the event stream makes no provider call after it.
 */
export async function runSandboxAttempt(input: SandboxLaunchInput, ports: SandboxLauncherPorts): Promise<void> {
  const lease = await bounded(ports.claimLease());
  const run = new SandboxRun(input, ports, lease);
  try {
    await run.execute();
  } catch (error) {
    await run.fail(error);
  } finally {
    await run.teardown();
  }
}

/** One attempt's state across its phases: boot and setup, the event loop, and teardown. */
class SandboxRun {
  private readonly startedAt: number;
  private readonly deadline: number;
  private readonly stop = new AbortController();
  private lateCreate: Promise<{ readonly providerVmId: string }> | undefined;
  private providerVmId: string | undefined;
  private handles: { readonly workspaceId: string; readonly terminalId: string } | undefined;
  private bootMs: number | null = null;
  private sequence = 0;
  private readonly tail = new OutputTail();
  private exitCode: number | null = null;
  private signal: number | null = null;
  private timedOut = false;
  private error: string | null = null;
  private closeEvents: (() => void) | undefined;

  constructor(
    private readonly input: SandboxLaunchInput,
    private readonly ports: SandboxLauncherPorts,
    private readonly lease: Lease,
  ) {
    this.startedAt = ports.now();
    this.deadline = (input.requestedAt ?? this.startedAt) + input.timeoutMs;
  }

  /** A teardown step: abandoned (as an error) after the step bound, so none can hang teardown. */
  private bounded<T>(work: Promise<T>, ms = this.input.teardownStepMs ?? SANDBOX_TEARDOWN_STEP_MS): Promise<T> {
    return bounded(work, ms);
  }

  /** `work`, or a deadline error once the one deadline passes. */
  private async step<T>(work: Promise<T>): Promise<T> {
    const result = await settleBefore(work, this.deadline - this.ports.now());
    if (result === "timeout") throw new SandboxDeadlineError(this.input.timeoutMs);
    return result.value;
  }

  async execute(): Promise<void> {
    const { input, ports, lease } = this;
    const creating = ports.createVm();
    this.lateCreate = creating;
    const providerVmId = (await this.step(creating)).providerVmId;
    this.providerVmId = providerVmId;
    this.lateCreate = undefined;
    this.bootMs = ports.now() - this.startedAt;
    await this.step(ports.recordStarted(lease, providerVmId));
    const prepared = await this.step(ports.prepare({
      runId: input.runId,
      attemptId: input.attemptId,
      index: 0,
      vmId: providerVmId,
      agent: input.agent,
      prompt: input.task,
      lease: { leaseId: lease.leaseToken, leaseEpoch: lease.leaseGeneration },
    }));
    const attempt = await this.step(ports.start(prepared));
    this.handles = { workspaceId: attempt.workspaceId, terminalId: attempt.terminalId };
    await this.step(ports.recordHandles(lease, attempt));
    await this.follow(attempt);
    if (this.timedOut) {
      await this.bounded(ports.closeTerminal(attempt)).catch((error: unknown) => ports.log("[runs] sandbox terminal close failed", error));
      this.error = new SandboxDeadlineError(input.timeoutMs).message;
      await this.bounded(ports.recordFailure(lease, this.error, this.sequence + 1, providerVmId));
    }
  }

  /**
   * Journal the run's events until the stream ends. After the terminal state only the output it
   * raced is left: keep reading, but never past a short drain window, so a stream that never ends
   * can't hold the VM.
   */
  private async follow(attempt: CloudVmAttemptRef): Promise<void> {
    const events = this.ports.events(attempt, this.stop.signal)[Symbol.asyncIterator]();
    this.closeEvents = () => {
      // Ends the generator at its next await; a pending provider call settles on its own timeout.
      void events.return?.()?.catch(() => undefined);
    };
    let drainUntil: number | undefined;
    for (;;) {
      const next = await settleBefore(events.next(), (drainUntil ?? this.deadline) - this.ports.now());
      if (next === "timeout") {
        this.timedOut = drainUntil === undefined;
        return;
      }
      if (next.value.done) return;
      const event = next.value.value;
      this.sequence = Math.max(this.sequence, event.seq);
      if (event.kind === "output") this.tail.append(event.payload.text);
      else ({ exitCode: this.exitCode, signal: this.signal } = exitOf(event.payload, this.exitCode, this.signal));
      // The terminal event ended the lease: output drained after it reaches the reply, not the journal.
      if (drainUntil === undefined) await this.step(this.ports.ingest(this.lease, event));
      if (event.kind === "state" && event.payload.status !== "running") {
        drainUntil = Math.min(this.deadline, this.ports.now() + (this.input.drainMs ?? SANDBOX_DRAIN_MS));
      }
    }
  }

  async fail(error: unknown): Promise<void> {
    this.timedOut = this.timedOut || error instanceof SandboxDeadlineError;
    try {
      // Redact the whole message first: a cut could split a credential from what marks it.
      const handles = [this.providerVmId, this.handles?.workspaceId, this.handles?.terminalId];
      const message = redactReceiptText(error instanceof Error ? error.message : String(error), handles).slice(0, 500);
      this.error = message;
      await this.bounded(this.ports.recordFailure(this.lease, message, this.sequence + 1, this.providerVmId));
    } catch (terminalError) {
      // A cancel fenced this lease; the cancel already finished the attempt.
      this.ports.log("[runs] sandbox attempt failure was not recorded", terminalError);
    }
  }

  async teardown(): Promise<void> {
    const { ports, lease } = this;
    this.stop.abort();
    this.closeEvents?.();
    // A create the deadline abandoned may still finish: wait for it within the provider create's
    // own bound so its VM is handed to the reaper too, not left for the sweep.
    if (this.lateCreate && !this.providerVmId) {
      const late = await settleBefore(this.lateCreate.catch(() => null), this.input.lateCreateWaitMs ?? SANDBOX_LATE_CREATE_MS);
      if (late !== "timeout" && late.value) this.providerVmId = late.value.providerVmId;
    }
    // The outcome goes first: it is fenced on the lease token the cleanup handoff clears.
    try {
      const reply = sandboxReply(this.tail.toString(), [this.providerVmId, this.handles?.workspaceId, this.handles?.terminalId]);
      await this.bounded(ports.recordOutcome(lease, { reply, exitCode: this.exitCode, signal: this.signal, timedOut: this.timedOut, bootMs: this.bootMs, error: this.error }));
    } catch (error) {
      ports.log("[runs] sandbox outcome was not recorded", error);
    }
    if (this.providerVmId) {
      try {
        await this.bounded(ports.scheduleCleanup(lease, this.providerVmId));
      } catch (error) {
        // Fenced by a cancel: finalizeAttemptCancellation already made the VM due now.
        ports.log("[runs] sandbox cleanup handoff skipped", error);
      }
    }
    try {
      await this.bounded(ports.destroyNow(), this.input.teardownStepMs ?? SANDBOX_DESTROY_MS);
    } catch (error) {
      ports.log("[runs] sandbox inline destroy failed; the retention reaper retries", error);
    }
  }
}
