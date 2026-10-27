// A small typed client for the cmux VM API: create, list, pause, resume,
// delete, exec and one acpmux agent turn. It wraps the generated client in
// `index.ts`; it is not a second API. Refusals are typed: a 402 carries the
// URL to upgrade (never retry it), a 429 carries the budget and retry delay.
import { createCmuxVmClient, type CmuxVmClientOptions, type CreateVmRequest, type Vm, type VmList } from "./index.ts";

export const DEFAULT_UPGRADE_URL = "https://cmux.com/pricing";

export class CmuxVmError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly tag: string,
    readonly body: unknown,
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = "CmuxVmError";
  }
}

/** 402: the team's plan does not include this. Show `upgradeUrl`; do not retry. */
export class CmuxVmPlanRequired extends CmuxVmError {
  constructor(message: string, body: unknown, readonly upgradeUrl: string) {
    super(message, 402, "PaymentRequired", body, false);
    this.name = "CmuxVmPlanRequired";
  }
}

/** 429: a team quota or rate limit. Retry after `retryAfterSeconds` when set. */
export class CmuxVmQuotaExceeded extends CmuxVmError {
  constructor(message: string, body: unknown, readonly budget: string | undefined, readonly retryAfterSeconds: number | undefined) {
    super(message, 429, "QuotaExceeded", body, true);
    this.name = "CmuxVmQuotaExceeded";
  }
}

export interface ExecResult {
  readonly exitCode: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

const text = (value: unknown): string | undefined => (typeof value === "string" && value !== "" ? value : undefined);

/** Turns a failed response into the typed error. */
export function toCmuxVmError(status: number, body: unknown): CmuxVmError {
  const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
  const message = text(record.message) ?? `cmux VM API ${status}`;
  if (status === 402) return new CmuxVmPlanRequired(message, body, text(record.upgradeUrl) ?? DEFAULT_UPGRADE_URL);
  if (status === 429) {
    const retry = typeof record.retryAfterSeconds === "number" ? record.retryAfterSeconds : undefined;
    return new CmuxVmQuotaExceeded(message, body, text(record.budget), retry);
  }
  return new CmuxVmError(message, status, text(record._tag) ?? "Error", body, status >= 500);
}

/** POSIX single-quote a word for the guest's shell. */
const quote = (word: string): string => `'${word.replaceAll("'", `'\\''`)}'`;

export function createCmuxVm(options: CmuxVmClientOptions) {
  const api = createCmuxVmClient(options);
  const ok = <T>(result: { data?: T; error?: unknown; response: Response }): T => {
    if (!result.response.ok) throw toCmuxVmError(result.response.status, result.error);
    return result.data as T;
  };
  const params = (vmId: string) => ({ params: { path: { vmId } } });
  return {
    create: async (request: CreateVmRequest = {}, idempotencyKey?: string): Promise<Vm> =>
      ok(await api.POST("/v1/vms", { body: request, ...(idempotencyKey === undefined ? {} : { headers: { "idempotency-key": idempotencyKey } }) })) as Vm,
    list: async (): Promise<VmList> => ok(await api.GET("/v1/vms", {})) as VmList,
    get: async (vmId: string): Promise<Vm> => ok(await api.GET("/v1/vms/{vmId}", params(vmId))) as Vm,
    pause: async (vmId: string): Promise<Vm> => ok(await api.POST("/v1/vms/{vmId}/pause", params(vmId))) as Vm,
    resume: async (vmId: string): Promise<Vm> => ok(await api.POST("/v1/vms/{vmId}/resume", params(vmId))) as Vm,
    delete: async (vmId: string): Promise<void> => {
      ok(await api.DELETE("/v1/vms/{vmId}", params(vmId)));
    },
    exec: async (vmId: string, command: string, extra: { timeoutMs?: number; env?: Record<string, string> } = {}): Promise<ExecResult> =>
      ok(await api.POST("/v1/vms/{vmId}/exec", { ...params(vmId), body: { command, ...extra } })) as ExecResult,
    /** One agent turn: `acpmux run -m <model> <prompt>` on the VM. */
    acpmuxRun: async (vmId: string, prompt: string, extra: { model?: string; timeoutMs?: number } = {}): Promise<ExecResult> => {
      const command = `acpmux run -m ${quote(extra.model ?? "claude")} ${quote(prompt)}`;
      const result = ok(await api.POST("/v1/vms/{vmId}/exec", { ...params(vmId), body: { command, ...(extra.timeoutMs === undefined ? {} : { timeoutMs: extra.timeoutMs }) } })) as ExecResult;
      if (result.exitCode === 127) throw new CmuxVmError(`acpmux is not installed on ${vmId}: ${result.stderr.trim()}`, 200, "AcpmuxMissing", result, false);
      return result;
    },
  };
}
