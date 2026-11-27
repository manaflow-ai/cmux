import type { ExecResult, ExecOptions, VMProvider } from "./drivers/types";

/**
 * The first Run provider is deliberately small. It speaks the cmux-tui CLI
 * already shipped in a Cloud VM and keeps the Run service independent from the
 * provider SDK. Fan-out is one detached terminal per attempt; the proposed
 * `vm.agent_fan_out` daemon method is not assumed to exist yet.
 */

export const CLOUD_VM_TUI_BIN = "/usr/local/bin/cmux-tui";
export const CLOUD_VM_SESSION = "cloud";
export const CLOUD_VM_AGENT_BIN = "/usr/local/bin/cmux";
export const CLOUD_VM_RECEIPT_PAGE_SIZE = 30_000;

export const CLOUD_VM_AGENTS = ["claude", "codex", "opencode", "pi"] as const;
export type CloudVmAgent = (typeof CLOUD_VM_AGENTS)[number];

export type CloudVmAttemptLease = {
  readonly leaseId: string;
  readonly leaseEpoch: number;
};

export type CloudVmRunAttemptSpec = {
  readonly runId: string;
  readonly attemptId: string;
  readonly index: number;
  readonly vmId: string;
  readonly agent: CloudVmAgent;
  /** Prompt text is passed as one argv value after `--`; no shell is used. */
  readonly prompt: string;
  readonly cwd?: string;
  readonly workspaceName?: string;
  readonly lease?: CloudVmAttemptLease;
};

/**
 * A durable, provider-managed workspace without a one-shot agent terminal.
 *
 * The correlation key is the durable runtime's creation key.  The daemon
 * treats retries with the same key as a replay, which lets the control plane
 * recover after a lost provider response without creating a second workspace.
 */
export type CloudVmWorkspaceSpec = {
  readonly runtimeId: string;
  readonly vmId: string;
  readonly workspaceName: string;
  readonly workspaceKey?: string;
};

export type CloudVmWorkspaceRef = {
  readonly provider: "cloud-vm";
  readonly runtimeId: string;
  readonly vmId: string;
  readonly workspaceId: string;
  readonly workspaceKey: string;
  readonly replayed: boolean;
};

export type CloudVmPersistentTerminalSpec = {
  readonly runtimeId: string;
  readonly vmId: string;
  readonly workspaceId: string;
  readonly terminalName?: string;
  readonly terminalKey?: string;
  readonly agent: CloudVmAgent;
  readonly prompt: string;
  readonly cwd?: string;
};

export type CloudVmPersistentTerminalRef = {
  readonly provider: "cloud-vm";
  readonly runtimeId: string;
  readonly vmId: string;
  readonly workspaceId: string;
  readonly terminalId: string;
  readonly terminalKey: string;
  readonly replayed: boolean;
};

export type CloudVmPreparedAttempt = {
  readonly provider: "cloud-vm";
  readonly vmId: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly index: number;
  readonly agent: CloudVmAgent;
  readonly prompt: string;
  readonly cwd?: string;
  /** Stable daemon creation key. Retrying it replays the same workspace. */
  readonly workspaceKey: string;
  /** Stable daemon creation key. Retrying it replays the same terminal. */
  readonly terminalKey: string;
  readonly workspaceName: string;
  readonly terminalName: string;
  readonly lease?: CloudVmAttemptLease;
};

export type CloudVmAttemptRef = {
  readonly provider: "cloud-vm";
  readonly vmId: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly index: number;
  readonly workspaceId: string;
  readonly terminalId: string;
  readonly workspaceKey: string;
  readonly terminalKey: string;
  readonly lease?: CloudVmAttemptLease;
  readonly replayed: boolean;
};

export type CloudVmTerminalStatus = "running" | "succeeded" | "failed" | "cancelled";

export type CloudVmTerminalReceipt = {
  readonly terminalId: string;
  readonly status: CloudVmTerminalStatus;
  readonly exitCode?: number;
  readonly signal?: number;
};

export type CloudVmOutputPage = {
  readonly terminalId: string;
  readonly text: string;
  readonly startOffset: number;
  readonly nextOffset: number;
  readonly complete: boolean;
};

export type CloudVmRunEvent =
  | {
      readonly kind: "output";
      readonly eventId: string;
      readonly seq: number;
      readonly payload: { readonly text: string; readonly startOffset: number; readonly nextOffset: number };
    }
  | {
      readonly kind: "state";
      readonly eventId: string;
      readonly seq: number;
      readonly payload: CloudVmTerminalReceipt;
    };

export type CloudVmCollectedAttempt = {
  readonly receipt: CloudVmTerminalReceipt;
  readonly output: string;
};

export class CloudVmRunAdapterError extends Error {
  readonly code: string;
  readonly details?: unknown;

  constructor(code: string, message: string, details?: unknown) {
    super(message);
    this.name = "CloudVmRunAdapterError";
    this.code = code;
    this.details = details;
  }
}

type ExecTransport = Pick<VMProvider, "exec">;

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function safeKey(label: string, value: string): string {
  if (!value || Buffer.byteLength(value, "utf8") > 128 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new CloudVmRunAdapterError("invalid_key", `${label} must be 1 to 128 bytes without control characters`);
  }
  return value;
}

function safeId(label: string, value: string): string {
  if (!/^[A-Za-z0-9._:-]{1,160}$/.test(value)) {
    throw new CloudVmRunAdapterError("invalid_id", `${label} has an invalid shape`);
  }
  return value;
}

function jsonObject(stdout: string, operation: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(stdout);
  } catch (cause) {
    throw new CloudVmRunAdapterError("invalid_receipt", `${operation} returned invalid JSON`, cause);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new CloudVmRunAdapterError("invalid_receipt", `${operation} returned a non-object receipt`);
  }
  return value as Record<string, unknown>;
}

function unwrap(value: Record<string, unknown>): Record<string, unknown> {
  const nested = value.value;
  return nested && typeof nested === "object" && !Array.isArray(nested)
    ? { ...(nested as Record<string, unknown>), ...(typeof value.replayed === "boolean" ? { replayed: value.replayed } : {}) }
    : value;
}

function stringField(value: Record<string, unknown>, ...names: string[]): string | undefined {
  for (const name of names) {
    if (typeof value[name] === "string" && value[name]) return value[name];
  }
  return undefined;
}

function integerField(value: Record<string, unknown>, ...names: string[]): number | undefined {
  for (const name of names) {
    if (typeof value[name] === "number" && Number.isSafeInteger(value[name])) return value[name];
  }
  return undefined;
}

function commandResult(result: ExecResult, operation: string): Record<string, unknown> {
  if (result.exitCode !== 0) {
    throw new CloudVmRunAdapterError(
      "guest_command_failed",
      `${operation} failed with exit ${result.exitCode}`,
      { exitCode: result.exitCode },
    );
  }
  return jsonObject(result.stdout, operation);
}

function terminalIdFrom(value: Record<string, unknown>, operation: string): string {
  const terminalId = idValue(value, "terminal_id", "terminalId")
    ?? nestedId(value.terminal);
  if (!terminalId) throw new CloudVmRunAdapterError("invalid_receipt", `${operation} returned no terminal id`);
  return terminalId;
}

function workspaceIdFrom(value: Record<string, unknown>, operation: string): string {
  const workspaceId = idValue(value, "workspace_id", "workspaceId")
    ?? nestedId(value.workspace);
  if (!workspaceId) throw new CloudVmRunAdapterError("invalid_receipt", `${operation} returned no workspace id`);
  return workspaceId;
}

function nestedId(value: unknown): string | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const object = value as Record<string, unknown>;
  return idValue(object, "id", "workspace_id", "workspaceId", "terminal_id", "terminalId");
}

function idValue(value: Record<string, unknown>, ...names: string[]): string | undefined {
  for (const name of names) {
    const candidate = value[name];
    if (typeof candidate === "string" && candidate) return candidate;
    if (typeof candidate === "number" && Number.isSafeInteger(candidate)) return String(candidate);
  }
  return undefined;
}

function commandPrefix(): string {
  return `${CLOUD_VM_TUI_BIN} --session ${shellQuote(CLOUD_VM_SESSION)} --json`;
}

function createWorkspaceCommand(prepared: CloudVmPreparedAttempt): string {
  return [
    commandPrefix(), "workspace", "create", "--empty",
    "--name", shellQuote(prepared.workspaceName),
    "--correlation-key", shellQuote(prepared.workspaceKey),
  ].join(" ");
}

export function prepareCloudVmWorkspace(spec: CloudVmWorkspaceSpec): CloudVmWorkspaceSpec & { readonly workspaceKey: string } {
  safeId("runtimeId", spec.runtimeId);
  safeId("vmId", spec.vmId);
  const workspaceName = spec.workspaceName.trim();
  if (!workspaceName) throw new CloudVmRunAdapterError("invalid_workspace_name", "workspaceName cannot be empty");
  const workspaceKey = safeKey("workspace correlation key", spec.workspaceKey ?? `cmux-runtime:${spec.runtimeId}:workspace`);
  safeKey("workspace name", workspaceName);
  return { ...spec, workspaceName, workspaceKey };
}

function workspaceCommand(spec: CloudVmWorkspaceSpec & { readonly workspaceKey: string }): string {
  return [
    commandPrefix(), "workspace", "create", "--empty",
    "--name", shellQuote(spec.workspaceName),
    "--correlation-key", shellQuote(spec.workspaceKey),
  ].join(" ");
}

function createTerminalCommand(prepared: CloudVmPreparedAttempt, workspaceId: string): string {
  const command = [
    commandPrefix(), "workspace", shellQuote(workspaceId), "run", "--on-exit", "keep",
    "--correlation-key", shellQuote(prepared.terminalKey),
    "--name", shellQuote(prepared.terminalName),
  ];
  if (prepared.cwd) command.push("--cwd", shellQuote(prepared.cwd));
  command.push("--", shellQuote(CLOUD_VM_AGENT_BIN), "agent", shellQuote(prepared.agent), "--", shellQuote(prepared.prompt));
  return command.join(" ");
}

function persistentTerminalCommand(spec: CloudVmPersistentTerminalSpec & {
  readonly terminalName: string;
  readonly terminalKey: string;
}): string {
  const command = [
    commandPrefix(), "workspace", shellQuote(spec.workspaceId), "run", "--on-exit", "keep",
    "--correlation-key", shellQuote(spec.terminalKey),
    "--name", shellQuote(spec.terminalName),
  ];
  if (spec.cwd) command.push("--cwd", shellQuote(spec.cwd));
  command.push("--", shellQuote(CLOUD_VM_AGENT_BIN), "agent", shellQuote(spec.agent), "--", shellQuote(spec.prompt));
  return command.join(" ");
}

function preparePersistentTerminal(spec: CloudVmPersistentTerminalSpec): CloudVmPersistentTerminalSpec & {
  readonly terminalName: string;
  readonly terminalKey: string;
} {
  safeId("runtimeId", spec.runtimeId);
  safeId("vmId", spec.vmId);
  safeId("workspaceId", spec.workspaceId);
  if (!CLOUD_VM_AGENTS.includes(spec.agent)) {
    throw new CloudVmRunAdapterError("unsupported_agent", `unsupported cloud agent ${JSON.stringify(spec.agent)}`);
  }
  if (!spec.prompt) throw new CloudVmRunAdapterError("invalid_prompt", "terminal prompt cannot be empty");
  if (spec.cwd !== undefined && (!spec.cwd || /[\u0000]/.test(spec.cwd))) {
    throw new CloudVmRunAdapterError("invalid_cwd", "terminal cwd must be a non-empty path");
  }
  const terminalName = spec.terminalName?.trim() || `runtime:${spec.runtimeId}`;
  safeKey("terminal name", terminalName);
  const terminalKey = safeKey("terminal correlation key", spec.terminalKey ?? `cmux-runtime:${spec.runtimeId}:terminal`);
  return { ...spec, terminalName, terminalKey };
}

function terminalWaitCommand(terminalId: string, timeoutMs: number): string {
  return [
    commandPrefix(), "terminal", shellQuote(terminalId), "process", "wait",
    "--timeout-ms", String(timeoutMs),
  ].join(" ");
}

function terminalOutputCommand(terminalId: string, after: number): string {
  return [commandPrefix(), "terminal", shellQuote(terminalId), "output", "read", "--after", String(after)].join(" ");
}

function terminalCloseCommand(terminalId: string): string {
  return [commandPrefix(), "terminal", shellQuote(terminalId), "close"].join(" ");
}

function normalizeTimeout(timeoutMs: number | undefined): number {
  if (timeoutMs === undefined) return CLOUD_VM_RECEIPT_PAGE_SIZE;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > CLOUD_VM_RECEIPT_PAGE_SIZE) {
    throw new CloudVmRunAdapterError("invalid_timeout", "timeoutMs must be an integer from 1 to 30000");
  }
  return timeoutMs;
}

function terminalReceipt(value: Record<string, unknown>, expectedTerminalId: string): CloudVmTerminalReceipt {
  const terminalId = terminalIdFrom(value, "terminal process wait");
  if (terminalId !== expectedTerminalId) {
    throw new CloudVmRunAdapterError("receipt_mismatch", "terminal process receipt named a different terminal", { terminalId, expectedTerminalId });
  }
  const state = stringField(value, "state", "lifecycle");
  if (state === "pending" || state === "starting" || state === "running" || state === undefined) {
    return { terminalId, status: "running" };
  }
  if (state !== "exited" && state !== "closed" && state !== "cancelled") {
    throw new CloudVmRunAdapterError("invalid_receipt", `unknown terminal state ${JSON.stringify(state)}`);
  }
  const outcome = value.outcome && typeof value.outcome === "object" && !Array.isArray(value.outcome)
    ? value.outcome as Record<string, unknown>
    : value;
  const kind = stringField(outcome, "kind");
  const code = integerField(outcome, "code", "exit_code", "exitCode");
  const signal = integerField(outcome, "signal");
  if (state === "cancelled") return { terminalId, status: "cancelled", ...(signal === undefined ? {} : { signal }) };
  if (kind === "signal") return { terminalId, status: "failed", ...(signal === undefined ? {} : { signal }) };
  return { terminalId, status: code === 0 ? "succeeded" : "failed", ...(code === undefined ? {} : { exitCode: code }) };
}

function outputPage(value: Record<string, unknown>, expectedTerminalId: string, after: number): CloudVmOutputPage {
  const terminalId = terminalIdFrom(value, "terminal output read");
  if (terminalId !== expectedTerminalId) {
    throw new CloudVmRunAdapterError("receipt_mismatch", "terminal output receipt named a different terminal", { terminalId, expectedTerminalId });
  }
  const startOffset = integerField(value, "start_offset", "startOffset");
  const nextOffset = integerField(value, "next_offset", "nextOffset");
  const text = typeof value.text === "string" ? value.text : undefined;
  const complete = typeof value.complete === "boolean" ? value.complete : undefined;
  if (startOffset === undefined || nextOffset === undefined || text === undefined || complete === undefined) {
    throw new CloudVmRunAdapterError("invalid_receipt", "terminal output receipt is missing paging fields");
  }
  if (startOffset !== after || nextOffset < startOffset) {
    throw new CloudVmRunAdapterError("replay_gap", "terminal output receipt is out of order", { after, startOffset, nextOffset });
  }
  return { terminalId, text, startOffset, nextOffset, complete };
}

export function prepareCloudVmRunAttempt(spec: CloudVmRunAttemptSpec): CloudVmPreparedAttempt {
  safeId("runId", spec.runId);
  safeId("attemptId", spec.attemptId);
  safeId("vmId", spec.vmId);
  if (!Number.isSafeInteger(spec.index) || spec.index < 0) {
    throw new CloudVmRunAdapterError("invalid_index", "attempt index must be a non-negative integer");
  }
  if (!CLOUD_VM_AGENTS.includes(spec.agent)) {
    throw new CloudVmRunAdapterError("unsupported_agent", `unsupported cloud agent ${JSON.stringify(spec.agent)}`);
  }
  if (!spec.prompt) throw new CloudVmRunAdapterError("invalid_prompt", "attempt prompt cannot be empty");
  if (spec.cwd !== undefined && (!spec.cwd || /[\u0000]/.test(spec.cwd))) {
    throw new CloudVmRunAdapterError("invalid_cwd", "attempt cwd must be a non-empty path");
  }
  const workspaceKey = safeKey("workspace correlation key", `cmux-run:${spec.runId}:${spec.attemptId}:workspace`);
  const terminalKey = safeKey("terminal correlation key", `cmux-run:${spec.runId}:${spec.attemptId}:terminal`);
  const workspaceName = spec.workspaceName || `run-${spec.runId}-${spec.index}`;
  safeKey("workspace name", workspaceName);
  const terminalName = `run:${spec.runId}:${spec.attemptId}`;
  safeKey("terminal name", terminalName);
  return {
    provider: "cloud-vm", vmId: spec.vmId, runId: spec.runId, attemptId: spec.attemptId,
    index: spec.index, agent: spec.agent, prompt: spec.prompt, cwd: spec.cwd,
    workspaceKey, terminalKey, workspaceName, terminalName, lease: spec.lease,
  };
}

export class CloudVmRunAdapter {
  readonly provider = "cloud-vm" as const;

  constructor(private readonly transport: ExecTransport) {}

  /**
   * Create (or replay) a durable daemon workspace without starting a command.
   *
   * Persistent workspace lifecycle owns the VM separately from the terminal
   * run adapter. Keeping this operation here reuses the same JSON receipt
   * validation, shell quoting, and correlation-key replay guarantees as Run.
   */
  async createWorkspace(spec: CloudVmWorkspaceSpec): Promise<CloudVmWorkspaceRef> {
    const prepared = prepareCloudVmWorkspace(spec);
    const result = await this.transport.exec(prepared.vmId, workspaceCommand(prepared), this.execOptions());
    const workspace = unwrap(commandResult(result, "workspace create"));
    return {
      provider: "cloud-vm",
      runtimeId: prepared.runtimeId,
      vmId: prepared.vmId,
      workspaceId: workspaceIdFrom(workspace, "workspace create"),
      workspaceKey: prepared.workspaceKey,
      replayed: workspace.replayed === true,
    };
  }

  /** Create (or replay) a kept terminal in an already-created durable workspace. */
  async createTerminal(spec: CloudVmPersistentTerminalSpec): Promise<CloudVmPersistentTerminalRef> {
    const prepared = preparePersistentTerminal(spec);
    const result = await this.transport.exec(prepared.vmId, persistentTerminalCommand(prepared), this.execOptions());
    const terminal = unwrap(commandResult(result, "workspace run"));
    return {
      provider: "cloud-vm",
      runtimeId: prepared.runtimeId,
      vmId: prepared.vmId,
      workspaceId: prepared.workspaceId,
      terminalId: terminalIdFrom(terminal, "workspace run"),
      terminalKey: prepared.terminalKey,
      replayed: terminal.replayed === true,
    };
  }

  async prepareAttempt(spec: CloudVmRunAttemptSpec): Promise<CloudVmPreparedAttempt> {
    return prepareCloudVmRunAttempt(spec);
  }

  /**
   * Provider calls are lease-fenced by the Run service. Keeping this check at
   * the adapter seam makes it difficult for a recovered worker to accidentally
   * drive a terminal after its lease was replaced.
   */
  assertLease(attempt: CloudVmAttemptRef, lease: CloudVmAttemptLease): void {
    if (!attempt.lease || attempt.lease.leaseId !== lease.leaseId || attempt.lease.leaseEpoch !== lease.leaseEpoch) {
      throw new CloudVmRunAdapterError("stale_lease", "cloud VM attempt lease is no longer current", {
        attemptLeaseId: attempt.lease?.leaseId,
        attemptLeaseEpoch: attempt.lease?.leaseEpoch,
      });
    }
  }

  async start(prepared: CloudVmPreparedAttempt): Promise<CloudVmAttemptRef> {
    const workspaceResult = await this.transport.exec(prepared.vmId, createWorkspaceCommand(prepared), this.execOptions());
    const workspace = unwrap(commandResult(workspaceResult, "workspace create"));
    const workspaceId = workspaceIdFrom(workspace, "workspace create");
    const terminalResult = await this.transport.exec(prepared.vmId, createTerminalCommand(prepared, workspaceId), this.execOptions());
    const terminal = unwrap(commandResult(terminalResult, "workspace run"));
    return {
      provider: "cloud-vm", vmId: prepared.vmId, runId: prepared.runId, attemptId: prepared.attemptId,
      index: prepared.index, workspaceId, terminalId: terminalIdFrom(terminal, "workspace run"),
      workspaceKey: prepared.workspaceKey, terminalKey: prepared.terminalKey, lease: prepared.lease,
      replayed: terminal.replayed === true || workspace.replayed === true,
    };
  }

  async readReceipt(attempt: CloudVmAttemptRef, timeoutMs?: number): Promise<CloudVmTerminalReceipt> {
    const timeout = normalizeTimeout(timeoutMs);
    const result = await this.transport.exec(attempt.vmId, terminalWaitCommand(attempt.terminalId, timeout), this.execOptions(timeout + 5_000));
    const value = unwrap(commandResult(result, "terminal process wait"));
    return terminalReceipt(value, attempt.terminalId);
  }

  async readOutput(attempt: CloudVmAttemptRef, after = 0): Promise<CloudVmOutputPage> {
    if (!Number.isSafeInteger(after) || after < 0) {
      throw new CloudVmRunAdapterError("invalid_offset", "output offset must be a non-negative integer");
    }
    const result = await this.transport.exec(attempt.vmId, terminalOutputCommand(attempt.terminalId, after), this.execOptions());
    return outputPage(unwrap(commandResult(result, "terminal output read")), attempt.terminalId, after);
  }

  /** `signal`: once aborted, the stream ends before its next provider call. */
  async *events(attempt: CloudVmAttemptRef, after = 0, signal?: AbortSignal): AsyncGenerator<CloudVmRunEvent> {
    let offset = after;
    let state: CloudVmTerminalStatus | undefined;
    while (!signal?.aborted) {
      const page = await this.readOutput(attempt, offset);
      if (page.text) {
        yield {
          kind: "output", eventId: `${attempt.attemptId}:output:${page.startOffset}`, seq: eventSeq(page.nextOffset),
          payload: { text: page.text, startOffset: page.startOffset, nextOffset: page.nextOffset },
        };
      }
      offset = page.nextOffset;
      if (signal?.aborted) return;
      const receipt = await this.readReceipt(attempt);
      if (receipt.status !== state) {
        state = receipt.status;
        yield { kind: "state", eventId: `${attempt.attemptId}:state:${receipt.status}`, seq: eventSeq(offset, receipt.status), payload: receipt };
      }
      if (receipt.status !== "running" && page.complete) return;
      // The receipt read above is the bounded long-poll. The next iteration
      // reads from the same cursor and waits again; it never starts another
      // unbounded stream or a shell-side sleep loop.
    }
  }

  async collect(attempt: CloudVmAttemptRef): Promise<CloudVmCollectedAttempt> {
    let offset = 0;
    let output = "";
    for (;;) {
      const page = await this.readOutput(attempt, offset);
      output += page.text;
      offset = page.nextOffset;
      if (page.complete) break;
      if (page.nextOffset === page.startOffset) await this.readReceipt(attempt);
    }
    return { receipt: await this.readReceipt(attempt), output };
  }

  async cancel(attempt: CloudVmAttemptRef): Promise<void> {
    const result = await this.transport.exec(attempt.vmId, terminalCloseCommand(attempt.terminalId), this.execOptions());
    if (result.exitCode === 0) return;
    const diagnostic = `${result.stderr}\n${result.stdout}`.toLowerCase();
    if (diagnostic.includes("not found") || diagnostic.includes("already closed") || diagnostic.includes("tombstone")) return;
    throw new CloudVmRunAdapterError("guest_command_failed", `terminal close failed with exit ${result.exitCode}`, {
      exitCode: result.exitCode,
    });
  }

  /** Terminal receipts remain durable after completion; cleanup is explicit cancel only. */
  async cleanup(attempt: CloudVmAttemptRef): Promise<void> {
    void attempt;
    return;
  }

  private execOptions(timeoutMs = 35_000): ExecOptions {
    return { timeoutMs };
  }
}

/** Map terminal byte offsets to a stable, strictly ordered Run-event hint. */
function eventSeq(offset: number, state?: CloudVmTerminalStatus): number {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > Math.floor(Number.MAX_SAFE_INTEGER / 2)) {
    throw new CloudVmRunAdapterError("invalid_offset", "terminal offset cannot be represented as an event cursor");
  }
  return offset * 4 + (state === undefined ? 0 : ({ running: 1, succeeded: 2, failed: 3, cancelled: 4 } as const)[state]);
}

