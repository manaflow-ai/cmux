import type { CloudVmAgent, CloudVmAttemptRef, CloudVmPreparedAttempt, CloudVmRunAttemptSpec, CloudVmRunEvent } from "../vms/cloudVmRunAdapter";
import type { SandboxRunOutcome } from "./model";
import { isYamlSecretHeader, redactReceiptText, sandboxReply, stripTerminalEscapes } from "./sandbox";

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

// A marker is BEGIN or END, then anything on that line, then PRIVATE KEY: whatever sits between
// (escape remnants, junk) can't hide one.
const KEY_BEGIN = /-----BEGIN[^\n]*?PRIVATE KEY/g;
const KEY_END = /-----END[^\n]*?PRIVATE KEY/g;
/** How much of a dropped line is kept to find a key marker split across chunks. */
const KEY_MARKER_WINDOW = 256;
/** A whole CSI sequence or two-character escape at the start of the text. */
const SHORT_ESCAPE = /^(?:\u001b\[[0-?]*[ -/]*[@-~]|\u001b[@-Z\\-_])/;
/** A CSI sequence still waiting for its final byte. */
const UNFINISHED_CSI = /^\u001b\[[0-?]*[ -/]*$/;
/** The longest unfinished CSI sequence carried to the next chunk; a longer one is dropped. */
const ESCAPE_CARRY_MAX = 4_096;

/**
 * Terminal output with its escape sequences removed as a terminal reads them, across chunks
 * and lines: an OSC sequence (`ESC ]`) swallows everything, newlines included, until its BEL or
 * ST, however long; a CSI sequence or escape a chunk ends in the middle of waits for the rest.
 * What the filter returns is the text a person would see, so markers and labels split by an
 * escape read whole.
 */
export class TerminalTextFilter {
  private carry = "";
  private inOsc = false;

  push(chunk: string): string {
    const text = this.carry + chunk;
    this.carry = "";
    let out = "";
    let at = 0;
    while (at < text.length) {
      if (this.inOsc) {
        const end = oscEnd(text, at);
        if (end < 0) {
          // An ESC at the very end may start the ST that ends the sequence.
          if (text.endsWith("\u001b")) this.carry = "\u001b";
          return out;
        }
        this.inOsc = false;
        at = end;
        continue;
      }
      const esc = text.indexOf("\u001b", at);
      if (esc < 0) return out + text.slice(at);
      out += text.slice(at, esc);
      const rest = text.slice(esc);
      if (rest.startsWith("\u001b]")) {
        this.inOsc = true;
        at = esc + 2;
        continue;
      }
      const whole = SHORT_ESCAPE.exec(rest);
      if (whole) {
        at = esc + whole[0].length;
        continue;
      }
      if (rest.length === 1 || (rest.length <= ESCAPE_CARRY_MAX && UNFINISHED_CSI.test(rest))) {
        this.carry = rest;
        return out;
      }
      // A lone ESC that starts no sequence: dropped.
      at = esc + 1;
    }
    return out;
  }
}

/** Where the OSC sequence that `text` is inside of from `from` ends (after BEL or ST), or -1. */
function oscEnd(text: string, from: number): number {
  const bel = text.indexOf("\u0007", from);
  const st = text.indexOf("\u001b\\", from);
  if (bel < 0) return st < 0 ? -1 : st + 2;
  return st < 0 || bel < st ? bel + 1 : st + 2;
}

function lastIndexOf(pattern: RegExp, text: string): number {
  let last = -1;
  for (const match of text.matchAll(pattern)) last = match.index;
  return last;
}

/** Spaces and tabs this long or longer collapse to one space (they carry nothing for a reply). */
const LONG_BLANK = /[ \t]{64,}/g;
/**
 * A line's leading indent is kept (up to this long) instead: a YAML block's lines are its value
 * only while indented past its header, so collapsing indents could end a secret's block.
 */
const MAX_KEPT_INDENT = 1024;

/**
 * `text` (whole lines, then the start of one) with long blank runs collapsed and indents bounded.
 * An indent is cut to `MAX_KEPT_INDENT`, and a line opening a secret YAML block to one less, so
 * every line indented past such a header (its value, to the redactor) still is after the cut. An
 * unfinished line is cut again once it is whole: the caller re-collapses the unfinished part.
 */
function collapseBlanks(text: string): string {
  return text.replace(LONG_BLANK, (run: string, offset: number) => {
    const leading = offset === 0 || text[offset - 1] === "\n";
    // A blank line's run (it reaches the newline) is not an indent.
    if (!leading || text[offset + run.length] === "\n") return " ";
    const lineEnd = text.indexOf("\n", offset);
    // stripTerminalEscapes turns a carriage return (a CRLF line end) into a line break: drop it.
    const header = isYamlSecretHeader(stripTerminalEscapes(text.slice(offset + run.length, lineEnd < 0 ? undefined : lineEnd)).replace(/\n+$/, ""));
    return run.slice(0, header ? MAX_KEPT_INDENT - 1 : MAX_KEPT_INDENT);
  });
}
/** A probe no token shape or value pattern leaves whole when it sits where a secret's value goes. */
const VALUE_PROBE = "q7Zx4Kp9Wm2Rt6Vn8Ys3Bd5Hf";
/** A YAML block scalar header under a secret key, which the receipt's redactor reads as one. */
const YAML_STAND_IN = "secret: |";
/** Base64 that could be part of a key body. */
const BASE64_LINE = /^[A-Za-z0-9+/=]+\s*$/;

/**
 * The output a receipt may show: the last part of what a terminal would display, kept raw and
 * redacted whole by the receipt's own redactor when it is read, so a label and its value, a quote
 * and its close, or a key and its body are redacted together however the output was chunked.
 *
 * Only a window is kept (old lines drop off at line boundaries, so no token is ever cut in two),
 * and nothing is lost that redaction needs from beyond it:
 * - runs of blank lines and long runs of spaces collapse, so no amount of blank output can push a
 *   label away from its value;
 * - a line too long to keep is replaced by a placeholder, which keeps a label the line ended in
 *   (as the redactor reads it: the next line would be redacted as its value) as a stand-in label;
 * - a private key is dropped from its BEGIN line through its END line as it streams; an END with
 *   no BEGIN seen (the header hidden) takes back the base64 lines kept above it.
 */
export class OutputTail {
  private kept = "";
  private pending = "";
  private skippingLine = false;
  /** The end of the line being skipped (for markers and a label split across chunks). */
  private skippedTail = "";
  /** The start of the line being skipped (a quoted value it opens may run past its end). */
  private skippedHead = "";
  /** The skipped line's indent, whole (already bounded): its placeholder keeps the line's depth. */
  private skippedIndent: string | null = null;
  /** The line being skipped held an END marker with no BEGIN seen: its body is above it. */
  private skippedEnd = false;
  private inKeyBlock = false;
  private readonly terminal = new TerminalTextFilter();

  constructor(private readonly handles: () => readonly (string | null | undefined)[] = () => []) {}

  append(chunk: string): void {
    let next = this.terminal.push(chunk);
    if (this.skippingLine) {
      const end = next.indexOf("\n");
      this.skip(end < 0 ? next : next.slice(0, end));
      if (end < 0) return;
      next = next.slice(end + 1);
      this.endSkip();
    }
    this.pending = collapseBlanks(this.pending + next);
    let newline = this.pending.indexOf("\n");
    while (newline >= 0) {
      const line = this.pending.slice(0, newline + 1);
      // A whole line too long to keep goes the way of one that streamed past the window.
      if (line.length > SANDBOX_OUTPUT_TAIL_CHARS) {
        this.skip(line.slice(0, -1));
        this.endSkip();
      } else this.complete(line);
      this.pending = this.pending.slice(newline + 1);
      newline = this.pending.indexOf("\n");
    }
    if (this.pending.length > SANDBOX_OUTPUT_TAIL_CHARS) {
      this.skip(this.pending);
      this.pending = "";
      this.skippingLine = true;
    }
  }

  /** A line too long to keep: dropped, but its key markers and the label it ends in still count. */
  private skip(text: string): void {
    const clean = stripTerminalEscapes(text);
    let body = clean;
    if (this.skippedIndent === null) {
      // The first part of a skipped line holds its whole indent (collapseBlanks bounded it). The
      // head is read after it, so a deep line's head still shows what the line opens (a header).
      this.skippedIndent = /^[ \t]*/.exec(clean)?.[0] ?? "";
      body = clean.slice(this.skippedIndent.length);
    }
    if (this.skippedHead.length < KEY_MARKER_WINDOW) this.skippedHead = (this.skippedHead + body).slice(0, KEY_MARKER_WINDOW);
    const scan = this.skippedTail + clean;
    const begin = lastIndexOf(KEY_BEGIN, scan);
    const end = lastIndexOf(KEY_END, scan);
    if (begin > end) this.inKeyBlock = true;
    else if (end > begin && this.inKeyBlock) {
      this.inKeyBlock = false;
      this.keep("[redacted private key]\n");
    } else if (end > begin) this.skippedEnd = true;
    this.skippedTail = scan.slice(-KEY_MARKER_WINDOW);
  }

  private endSkip(): void {
    if (this.skippedEnd) {
      // An END on a line too long to keep, with no BEGIN seen: take back the body above it.
      this.kept = withoutKeyBody(this.kept);
      this.keep("[redacted private key]\n");
    } else if (!this.inKeyBlock) this.keep(`${omittedLine(this.skippedHead, this.skippedTail, this.skippedIndent ?? "")}\n`);
    this.skippingLine = false;
    this.skippedHead = "";
    this.skippedIndent = null;
    this.skippedTail = "";
    this.skippedEnd = false;
  }

  private complete(raw: string): void {
    // Control characters out (the terminal filter already took the escapes out).
    const line = stripTerminalEscapes(raw);
    if (lastIndexOf(KEY_BEGIN, line) >= 0) this.inKeyBlock = true;
    if (this.inKeyBlock) {
      if (lastIndexOf(KEY_END, line) >= 0) {
        this.inKeyBlock = false;
        this.keep("[redacted private key]\n");
      }
      return;
    }
    if (lastIndexOf(KEY_END, line) >= 0) {
      this.kept = withoutKeyBody(this.kept);
      this.keep("[redacted private key]\n");
      return;
    }
    // One blank line is as good as many: a run of them never pushes a label off the window.
    if (!line.trim() && (this.kept.endsWith("\n\n") || this.kept === "")) return;
    this.keep(line);
  }

  /**
   * Old output drops off a window at a time (so the redactor runs over each dropped block once).
   * When the dropped block ends where the redactor would still be inside a secret's value (an
   * open quote, or a label whose value is the next line), the kept text starts with a stand-in
   * label with the same effect, so dropping the label never exposes its value.
   */
  private keep(line: string): void {
    this.kept += line;
    if (this.kept.length <= 2 * SANDBOX_OUTPUT_TAIL_CHARS) return;
    const lineStart = this.kept.indexOf("\n", this.kept.length - SANDBOX_OUTPUT_TAIL_CHARS);
    if (lineStart < 0) return;
    const context = standIn(this.kept.slice(0, lineStart));
    this.kept = `${context ? `[earlier output omitted] ${context}` : ""}${this.kept.slice(lineStart + 1 - (context ? 1 : 0))}`;
  }

  toString(): string {
    // The unfinished last line counts too: a key block shows only its marker, an END takes back
    // its body, and a line still being skipped shows as omitted.
    let kept = this.kept;
    let last = stripTerminalEscapes(this.pending);
    if (this.skippingLine && this.skippedEnd) {
      kept = withoutKeyBody(kept);
      last = "[redacted private key]";
    } else if (this.skippingLine) last = this.inKeyBlock ? "[redacted private key]" : omittedLine(this.skippedHead, this.skippedTail, this.skippedIndent ?? "");
    else if (this.inKeyBlock) last = "[redacted private key]";
    else if (lastIndexOf(KEY_END, last) >= 0) {
      kept = withoutKeyBody(kept);
      last = "[redacted private key]";
    }
    return redactReceiptText(kept + last, this.handles());
  }
}

/**
 * The placeholder for a line too long to keep. When the line ends where a value would follow a
 * secret's label (the receipt's redactor would take the next line as that value), the
 * placeholder ends in a stand-in label with the same effect, open quote included. A line that
 * opens a quoted secret value at its start and shows no quote near its end is taken to be still
 * inside that value (the omitted middle can't be read; this errs toward redacting).
 */
function omittedLine(head: string, tail: string, indent: string): string {
  // A line that started a key block keeps saying so, so taking back a body stops there.
  // The line's own indent stays, so a long line inside a YAML block scalar doesn't end the block.
  const placeholder = `${indent}${head.includes("-----BEGIN") ? "[long line omitted] -----BEGIN" : "[long line omitted]"}`;
  const opened = standIn(head);
  const quote = opened.startsWith("secret=") ? opened.slice("secret=".length) : "";
  if (opened.startsWith("\n")) return `${placeholder} ${opened}`;
  // The value the line's start opened is closed only by its own quote character in what is left.
  if (quote && !tail.replace(/\\./g, "").includes(quote)) return `${placeholder} ${opened}`;
  const after = standIn(tail);
  return after ? `${placeholder} ${after}` : placeholder;
}

/**
 * The stand-in label for text the reply drops: `secret="` (or `secret='`) when the redactor
 * would read on past the text's end inside a quoted secret value, `secret=` when it would take
 * the next line as a secret's value, and nothing otherwise. Probed with the receipt's own
 * redactor, so its grammar is the one used everywhere.
 */
function standIn(text: string): string {
  if (redactReceiptText(`${text}\n${VALUE_PROBE}`).includes(VALUE_PROBE)) {
    // Inside a YAML block scalar under a secret key: its indented lines are the value. The
    // stand-in is a header of its own on a new line, at no indent, so it covers any indent.
    return redactReceiptText(`${text}\n${" ".repeat(deepestIndent(text) + 1)}${VALUE_PROBE}`).includes(VALUE_PROBE) ? "" : `\n${YAML_STAND_IN}`;
  }
  // Inside an open quote the redactor keeps going past a space; after a bare label it stops.
  if (redactReceiptText(`${text}\nZ ${VALUE_PROBE}`).includes(VALUE_PROBE)) return "secret=";
  // The quote that opened the value: the last one right after a label's `:` or `=` (a quote
  // character inside the value, an apostrophe in `it's`, is not it).
  const opened = [...text.replace(/\\./g, "").matchAll(/[:=]\s*(["'])/g)].at(-1)?.[1] ?? '"';
  return `secret=${opened}`;
}

/** The deepest leading indent of any line in `text`: a probe one deeper continues any block it opened. */
function deepestIndent(text: string): number {
  let deepest = 0;
  for (const match of text.matchAll(/^[ \t]+/gm)) deepest = Math.max(deepest, match[0].length);
  return deepest;
}

/** `kept` without the key body that ends it: base64 lines back to (and with) a line holding BEGIN. */
function withoutKeyBody(kept: string): string {
  const lines = kept.split("\n");
  const last = lines.pop() ?? "";
  let cut = lines.length;
  while (cut > 0) {
    const line = lines[cut - 1] ?? "";
    if (line.includes("-----BEGIN")) {
      cut -= 1;
      break;
    }
    // A body line too long to keep left a placeholder: still part of the body.
    if (!BASE64_LINE.test(line) && !line.trimStart().startsWith("[long line omitted]")) break;
    cut -= 1;
  }
  return [...lines.slice(0, cut), last].join("\n");
}

/**
 * The journal kind of a sandbox's event, or null for terminal output: events are served as
 * stored, so a sandbox journals no raw output; the receipt's redacted tail is its output.
 */
export function sandboxJournalKind(event: CloudVmRunEvent): "attempt.started" | "attempt.succeeded" | "attempt.failed" | null {
  if (event.kind === "output") return null;
  const status = event.payload.status;
  return status === "running" ? "attempt.started" : status === "succeeded" ? "attempt.succeeded" : "attempt.failed";
}

/** A state event's journal payload: its status and exit, never the adapter's terminal id (a provider handle). */
export function sandboxJournalPayload(event: CloudVmRunEvent): Record<string, unknown> {
  if (event.kind !== "state") return {};
  const { status, exitCode, signal } = event.payload;
  return { status, ...(exitCode === undefined ? {} : { exitCode }), ...(signal === undefined ? {} : { signal }) };
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
  /** Bookkeeping after the claim (the runtime row): bounded, and a failure is only logged. */
  readonly recordRuntime?: () => Promise<void>;
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
  private readonly tail = new OutputTail(() => [this.providerVmId, this.handles?.workspaceId, this.handles?.terminalId]);
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
    // A launch that starts with its budget already spent pays for no VM.
    if (ports.now() >= this.deadline) throw new SandboxDeadlineError(input.timeoutMs);
    // Inside the teardown's try, so a hang or failure here still ends in teardown; bounded by
    // the step bound and the request's remaining budget.
    if (ports.recordRuntime) {
      const ms = Math.min(input.teardownStepMs ?? SANDBOX_TEARDOWN_STEP_MS, this.deadline - ports.now());
      await bounded(ports.recordRuntime(), ms).catch((error: unknown) => ports.log("[runs] sandbox runtime bookkeeping failed", error));
      if (ports.now() >= this.deadline) throw new SandboxDeadlineError(input.timeoutMs);
    }
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
