import type { StringKey } from "./i18n";

/// A Sandboxed send (hq#3367, preview): the composer's environment picker can run a new chat's
/// first message as one task on a throwaway Cloud VM instead of a persistent chat. The host runs it
/// (`sandbox.run`, AgentPaneModel.onSandboxRun) and answers the Run's receipt
/// (`cmux.run.receipt/v1`, web/services/runs/model.ts); nothing of the VM is kept.

/// Where a new chat's first message runs: as a chat (the existing behavior), or once in a sandbox.
export type RunMode = "persistent" | "sandboxed";

/// The picker's Run as rows (EnvironmentPicker `runMode`).
export type RunModeRows = { mode: RunMode; onMode(mode: RunMode): void };

/// The parts of a receipt the chat shows; every field may be missing from an older server.
export type SandboxReceipt = {
  status?: string;
  exitCode?: number | null;
  timedOut?: boolean;
  reply?: string | null;
  artifacts?: { name?: string; sizeBytes?: number }[];
  timings?: { totalMs?: number | null; bootMs?: number | null };
  cost?: { vmSeconds?: number | null; estimateUsd?: number | null };
  cleanup?: string;
};

/// The chat's view of one Sandboxed send: running, its receipt, or why it didn't run.
export type SandboxRun =
  | { task: string; state: "running" }
  | { task: string; state: "done"; receipt: SandboxReceipt }
  | { task: string; state: "failed"; code: string };

/// The agents a sandbox can run (web/services/vms/cloudVmRunAdapter.ts CLOUD_VM_AGENTS).
const SANDBOX_AGENTS = new Set(["claude", "codex", "opencode", "pi"]);

/// The sandbox agent for the chat's harness (`claude-code` runs `claude`); undefined lets the
/// server pick its default.
export function sandboxAgent(harness: string | undefined): string | undefined {
  if (!harness) return undefined;
  const name = harness === "claude-code" ? "claude" : harness;
  return SANDBOX_AGENTS.has(name) ? name : undefined;
}

/// Runs `task` through the host and resolves to the finished view; never rejects.
export async function runSandbox(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  task: string,
  agent: string | undefined,
  key: string,
): Promise<SandboxRun> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    // The host answers within the task's 12 min cap plus its teardown; past that, the bridge is gone.
    const lost = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject({ code: "timeout" }), SANDBOX_PAGE_BOUND_MS);
    });
    const value = (await Promise.race([call("sandbox.run", { task, key, ...(agent ? { agent } : {}) }), lost])) as {
      receipt?: unknown;
    } | null;
    const receipt = pageReceipt(value?.receipt);
    if (!receipt) return { task, state: "failed", code: "bad_response" };
    return { task, state: "done", receipt };
  } catch (error) {
    const { code } = (error ?? {}) as { code?: unknown };
    return {
      task,
      state: "failed",
      code: typeof code === "string" && code ? code : "unavailable",
    };
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/// How long the page waits for the host's answer: the server's 12 min task cap, the host's 3 min
/// teardown margin and its 1 min for the calls, and a minute more.
export const SANDBOX_PAGE_BOUND_MS = 17 * 60_000;

/// Refusals that come before the server could create a Run: nothing runs, so the send may be tried
/// again (under a new key). Every other failure (a lost answer, a 500, no receipt in time) may hide
/// a live Run, so it keeps the chat's one send spent and tied to its task.
const DEFINITE_REFUSALS = new Set([
  "attachments",
  "agent",
  "unavailable_now",
  // The host's one-per-tab rule: one runs, or this tab's send already reached Cloud.
  "sandbox_busy",
  "sandbox_spent",
  "labs_off",
  "not_signed_in",
  "cloud_disabled",
  "run_sandbox_unavailable",
  "transport.gesture_required",
  "native.invalid_request",
  "unsupported",
  // The Run API's documented refusals of a request before it stores anything
  // (AgentPaneReply.runRequestRefusals); the host sends any other code as `unavailable`.
  "run_task_required",
  "run_agent_invalid",
  "run_image_invalid",
  "run_timeout_invalid",
  "run_attempts_invalid",
  "run_environment_invalid",
  "run_invalid_request",
]);

export function sandboxRetryable(run: SandboxRun): boolean {
  return run.state === "failed" && DEFINITE_REFUSALS.has(run.code);
}

/// A refusal the page can tell before asking the host: attachments, or an agent a sandbox can't run.
export function sandboxPageRefusal(attachmentCount: number, harness: string | undefined): string | undefined {
  // Attachments first: a pasted image alone is a send too, and it is the one a sandbox can't take.
  if (attachmentCount > 0) return "attachments";
  return harness && !sandboxAgent(harness) ? "agent" : undefined;
}

/// What the host says of this tab's Sandboxed send (`sandbox.state`, AgentPaneSandboxRuns): none,
/// one running, one that ended (its receipt or failure), or `unknown` when no read answered. The
/// host is the one truth: the page renders this and keeps nothing it decides itself.
export type SandboxHost =
  | { kind: "none" }
  | { kind: "unknown" }
  | { kind: "running"; task: string; key: string }
  | { kind: "ended"; task: string; key: string; run: SandboxRun };

/// The most a plain `sandbox.state` read may take (the host answers it at once).
const READ_MS = 15_000;
/// The host's one-send-per-tab refusals: it holds a send already.
const HOST_HOLDS_SEND = new Set(["sandbox_busy", "sandbox_spent"]);

/// One pane's Sandboxed send (hq#3367). The host holds the truth per tab and allows one paid send
/// (AgentPaneSandboxRuns): the page reads it at each handshake and after its own send, and renders
/// it. Of its own the page keeps only its send in flight (``mine``, bounded by the run's page bound)
/// and its own send's refusal before any Run (``refusal``; only that send puts its prompt back), and
/// the Run as pick.
export class SandboxTab {
  host: SandboxHost = { kind: "none" };
  /// This page's send in flight, with its attempt key (the idempotency key the host keeps).
  mine?: { task: string; key: string };
  /// A refusal before any Run (this page's own send's answer, or one the page told itself), shown
  /// until the person sends again or picks Persistent.
  refusal?: SandboxRun;
  /// The tab's confirmed receipt (its own send's answer, or a read): no failed or stale read
  /// replaces it, since the tab's one paid send is done.
  receipt?: SandboxRun;
  /// The attempt key of ``receipt``.
  private receiptKey?: string;
  mode: RunMode = "persistent";
  /// A read answered (none, running or ended): the page knows what the host holds for this tab, so
  /// Sandboxed can be offered.
  checked = false;
  /// The newest read didn't answer: the chat offers Check again. What the tab last knew (``host``)
  /// stays shown, so a run that may be live never drops out of view.
  unread = false;
  /// The attempt the host said reached Cloud (running, or ended other than by a refusal before any
  /// Run). It stays until that attempt's own refusal before any Run: a later read that fails can't
  /// make the tab's one paid send available again.
  private held?: string;
  private listeners = new Set<() => void>();
  private version = 0;
  /// The newest read: an older read's answer is dropped.
  private reads = 0;

  constructor(
    private readonly call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
    /// A refused send's prompt goes back to the composer.
    private readonly restore: (text: string) => void,
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  snapshot = () => this.version;

  /// What the tab shows as its Sandboxed result: the send in flight, its receipt, the host's run,
  /// or a refusal.
  view(): SandboxRun | undefined {
    if (this.receipt) return this.receipt;
    if (this.mine) return { task: this.mine.task, state: "running" };
    if (this.host.kind === "running") return { task: this.host.task, state: "running" };
    if (this.host.kind === "ended" && !sandboxRetryable(this.host.run)) return this.host.run;
    return this.refusal;
  }

  /// The tab's one paid send is out or used (the host refuses another): no new Sandboxed send.
  spent(): boolean {
    const view = this.view();
    return this.held !== undefined || (view !== undefined && !sandboxRetryable(view));
  }

  /// A send runs: a web update's reload waits (bounded by the send's and the read's deadlines). This
  /// page's own send holds it until its answer, even once a read found the tab's receipt: a refused
  /// send's prompt comes back only with that answer. A run the host reported holds it only while the
  /// newest read answered: once one fails (``unread``), the run stays in view but no longer holds a
  /// reload, since no timer is left to end the hold.
  busy(): boolean {
    return this.mine !== undefined || (this.receipt === undefined && !this.unread && this.host.kind === "running");
  }

  setMode(mode: RunMode) {
    this.mode = mode;
    if (mode === "persistent") this.refusal = undefined;
    this.emit();
  }

  /// A refusal the page tells itself (attachments, an agent a sandbox can't run, not now): shown in
  /// the chat; the composer keeps the prompt.
  refuse(task: string, code: string) {
    this.refusal = { task, state: "failed", code };
    this.emit();
  }

  /// Sends `text` as the tab's one Sandboxed send: false when one is out or used, or nothing to send.
  send(text: string, agent: string | undefined): boolean {
    if (this.spent() || !text.trim()) return false;
    // Reads already out describe the tab before this send: their answers are dropped.
    this.reads += 1;
    const key = crypto.randomUUID();
    this.mine = { task: text, key };
    this.refusal = undefined;
    this.emit();
    void runSandbox(this.call, text, agent, key).then((answer) => {
      // A read already ended this attempt (or the tab moved on): its late answer changes nothing.
      if (this.mine?.key !== key) return;
      // Reads out while it ran describe the tab before its answer: dropped. This answer is the host's
      // own for this attempt; a refusal before any Run puts its prompt back, here only.
      this.reads += 1;
      // A read during this send found another attempt holding the tab (its receipt, or a run that
      // may be live). The host allows one paid send per tab, so it refused this one
      // (`sandbox_spent`), whatever a lost answer says.
      const other = this.receiptKey ?? this.held;
      const done: SandboxRun =
        answer.state !== "done" && !sandboxRetryable(answer) && other && other !== key
          ? { task: text, state: "failed", code: "sandbox_spent" }
          : answer;
      const refused = sandboxRetryable(done);
      if (refused && !this.receipt && this.mode === "sandboxed") this.refusal = done;
      this.take({ kind: "ended", task: text, key, run: done });
      if (refused) this.restore(text);
      // The host already holds this tab's send (`sandbox_busy`, `sandbox_spent`), or the answer may
      // hide a live Run: read the host, so the tab's run or receipt shows.
      const holds = done.state === "failed" && HOST_HOLDS_SEND.has(done.code);
      // The host holds another send of this tab: none goes until a read says what it is (or none).
      if (holds) this.held ??= "";
      if (holds || (done.state !== "done" && !sandboxRetryable(done))) void this.read();
    });
    return true;
  }

  /// Reads the host's send (each handshake, Check again, a lost answer) and renders what it says.
  /// One plain read (15 s) and, for a running send, one wait read (the run's page bound): a read that
  /// fails or misses its deadline sets `unread` (with Check again) and keeps what the tab last knew;
  /// a newer read wins; nothing replaces a confirmed receipt.
  async read(): Promise<void> {
    if (this.receipt) return;
    const id = ++this.reads;
    const answer = await this.state({}, READ_MS);
    if (id !== this.reads || this.receipt) return;
    this.take(answer);
    if (answer.kind !== "running") return;
    const done = await this.state({ wait: true }, SANDBOX_PAGE_BOUND_MS);
    if (id !== this.reads || this.receipt) return;
    this.take(done);
  }

  /// One answer about an attempt (a read's, or the send's own): only what it shows, never the
  /// composer. An ended attempt retires the send in flight with the same key. A receipt is kept for
  /// good (the tab's one paid send). A refusal before any Run shows nothing here (``send`` shows its
  /// own; the host reports none).
  private take(answer: SandboxHost) {
    if (answer.kind === "ended" && this.mine?.key === answer.key) this.mine = undefined;
    if (answer.kind === "ended" && answer.run.state === "done") {
      if (!this.receipt) {
        this.receipt = answer.run;
        this.receiptKey = answer.key;
      }
      this.refusal = undefined;
    } else if (answer.kind === "running" || (answer.kind === "ended" && !sandboxRetryable(answer.run))) {
      this.refusal = undefined;
    }
    if (answer.kind === "unknown") {
      // No answer says nothing new: keep what the tab last knew (a run, a lost answer), with Check again.
      this.unread = true;
      if (!this.receipt && this.host.kind === "none") this.host = answer;
      this.emit();
      return;
    }
    this.unread = false;
    this.checked = true;
    if (answer.kind === "none") this.held = undefined;
    else if (answer.kind === "running" || (answer.kind === "ended" && !sandboxRetryable(answer.run)))
      this.held = answer.key;
    else if (answer.kind === "ended" && answer.key === this.held) this.held = undefined;
    if (!this.receipt) this.host = answer;
    this.emit();
  }

  private async state(params: { wait?: boolean }, bound: number): Promise<SandboxHost> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const value = (await Promise.race([
        this.call("sandbox.state", params),
        new Promise<never>((_, reject) => {
          // l10n-allow: caught below as an unknown state; never shown.
          timer = setTimeout(() => reject(new Error("sandbox.state timed out")), bound);
        }),
      ])) as { task?: unknown; key?: unknown; running?: unknown; reply?: unknown } | null;
      // `{}` (or null) is the host's "no send"; anything else that isn't a send is malformed.
      if (!value || (typeof value === "object" && Object.keys(value).length === 0)) return { kind: "none" };
      // A send with no attempt key can't be matched to this page's own send: malformed.
      if (typeof value.task !== "string" || typeof value.key !== "string" || !value.key) return { kind: "unknown" };
      const key = value.key;
      if (value.running === true) return { kind: "running", task: value.task, key };
      return { kind: "ended", task: value.task, key, run: fromReply(value.task, value.reply) };
    } catch {
      // No bridge, a timeout, a page-host error: unknown, with Check again. (An app without
      // `sandbox.state` is never read: its handshake doesn't say `sandboxState`.)
      return { kind: "unknown" };
    } finally {
      clearTimeout(timer);
    }
  }

  private emit() {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}

/// A host reply envelope (`{ok, value: {receipt}}` or `{ok: false, error: {code}}`) as a send.
function fromReply(task: string, reply: unknown): SandboxRun {
  const envelope = (reply ?? {}) as { ok?: unknown; value?: { receipt?: unknown }; error?: { code?: unknown } };
  const receipt = envelope.ok === true ? pageReceipt(envelope.value?.receipt) : undefined;
  if (receipt) return { task, state: "done", receipt };
  const code = envelope.error?.code;
  return { task, state: "failed", code: typeof code === "string" && code ? code : "unavailable" };
}

/// The string key for a failure the chat words itself; any other shows a generic line (the page
/// never shows the host's own text, which can name provider handles).
export function sandboxFailureKey(code: string): StringKey | undefined {
  switch (code) {
    case "labs_off":
      return "sandbox.error.labsOff";
    case "not_signed_in":
      return "sandbox.error.notSignedIn";
    case "run_sandbox_unavailable":
      return "sandbox.error.notEnabled";
    case "timeout":
      return "sandbox.error.timeout";
    case "unavailable":
    case "bad_response":
      return "sandbox.error.uncertain";
    case "sandbox_busy":
    case "sandbox_spent":
      return "sandbox.error.spent";
    case "cloud_disabled":
      return "sandbox.error.cloudDisabled";
    case "unavailable_now":
      return "sandbox.error.notNow";
    case "attachments":
      return "sandbox.error.attachments";
    case "agent":
      return "sandbox.error.agent";
    default:
      return undefined;
  }
}

/// The receipt's fields the chat shows, each of its own type (the host already sends no more); a
/// value that is no receipt is undefined.
function pageReceipt(value: unknown): SandboxReceipt | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const from = value as Record<string, unknown>;
  const text = (key: string) => (typeof from[key] === "string" ? (from[key] as string) : undefined);
  const number = (object: unknown, key: string) => {
    const field = object && typeof object === "object" ? (object as Record<string, unknown>)[key] : undefined;
    return typeof field === "number" && Number.isFinite(field) ? field : undefined;
  };
  const receipt: SandboxReceipt = {};
  const status = text("status");
  if (status !== undefined) receipt.status = status;
  const exitCode = number(from, "exitCode");
  if (exitCode !== undefined) receipt.exitCode = exitCode;
  if (typeof from.timedOut === "boolean") receipt.timedOut = from.timedOut;
  const reply = text("reply");
  if (reply !== undefined) receipt.reply = reply;
  const cleanup = text("cleanup");
  if (cleanup !== undefined) receipt.cleanup = cleanup;
  const totalMs = number(from.timings, "totalMs");
  const bootMs = number(from.timings, "bootMs");
  if (totalMs !== undefined || bootMs !== undefined) {
    receipt.timings = { ...(totalMs !== undefined ? { totalMs } : {}), ...(bootMs !== undefined ? { bootMs } : {}) };
  }
  const vmSeconds = number(from.cost, "vmSeconds");
  const estimateUsd = number(from.cost, "estimateUsd");
  if (vmSeconds !== undefined || estimateUsd !== undefined) {
    receipt.cost = {
      ...(vmSeconds !== undefined ? { vmSeconds } : {}),
      ...(estimateUsd !== undefined ? { estimateUsd } : {}),
    };
  }
  if (Array.isArray(from.artifacts)) {
    receipt.artifacts = from.artifacts.flatMap((artifact) => {
      if (!artifact || typeof artifact !== "object") return [];
      const name = (artifact as { name?: unknown }).name;
      const sizeBytes = number(artifact, "sizeBytes");
      return [{ ...(typeof name === "string" ? { name } : {}), ...(sizeBytes !== undefined ? { sizeBytes } : {}) }];
    });
  }
  return receipt;
}
