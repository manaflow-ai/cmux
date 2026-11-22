import { signInURL, type LoginAgent, type LoginStart } from "../agent-session/acpmux/cloudAgentLogin";
import { ExpiredSession } from "./wire";

export type MachineLoginStatus =
  | { waiting: true; harness: LoginAgent; login: LoginStart | null }
  | { signedIn: true; resumed: true };
export type MachineLoginFinish = { signedIn: false } | { signedIn: true; resumed: true };
export interface MachineLoginApi {
  status(run: string, signal: AbortSignal): Promise<MachineLoginStatus>;
  start(run: string, signal: AbortSignal): Promise<LoginStart>;
  finish(run: string, loginId: string, code: string | undefined, signal: AbortSignal): Promise<MachineLoginFinish>;
  cancel(run: string, loginId: string, signal: AbortSignal): Promise<void>;
}
export class MachineLoginError extends Error {
  constructor(
    readonly status: number,
    readonly code?: string,
  ) {
    // Provider errors and submitted codes never become displayed or logged error text.
    super("Machine sign-in failed");
    this.name = "MachineLoginError";
  }
}
const object = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);
const invalid = () => new MachineLoginError(502);
function loginOf(value: unknown): LoginStart {
  if (!object(value)) throw invalid();
  const url = signInURL(value.url);
  if (
    !url ||
    typeof value.loginId !== "string" ||
    !value.loginId.trim() ||
    ["\r", "\n", "\0"].some((character) => (value.loginId as string).includes(character)) ||
    typeof value.needsCode !== "boolean" ||
    (value.userCode !== undefined && typeof value.userCode !== "string") ||
    (value.expiresAtMs !== undefined && (typeof value.expiresAtMs !== "number" || !Number.isFinite(value.expiresAtMs)))
  )
    throw invalid();
  return {
    loginId: value.loginId,
    url,
    needsCode: value.needsCode,
    ...(typeof value.userCode === "string" ? { userCode: value.userCode } : {}),
    ...(typeof value.expiresAtMs === "number" ? { expiresAtMs: value.expiresAtMs } : {}),
  };
}
async function request(run: string, signal: AbortSignal, body?: Record<string, unknown>): Promise<unknown> {
  if (!/^run_[0-9]{1,15}$/.test(run)) throw new MachineLoginError(400, "validation.invalid");
  const controller = new AbortController();
  // Codex device approval may legitimately take sixteen minutes. Other calls remain short.
  const timer = setTimeout(() => controller.abort(), body?.action === "finish" ? 17 * 60_000 : 30_000);
  try {
    const response = await fetch(`/v1/chief/machine-login/${run}`, {
      method: body ? "POST" : "GET",
      credentials: "include",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      signal: AbortSignal.any([signal, controller.signal]),
      ...(body ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {}),
    });
    if (response.status === 401) throw new ExpiredSession();
    const envelope: unknown = await response.json().catch(() => undefined);
    if (!response.ok || !object(envelope) || envelope.ok !== true) {
      const error = object(envelope) && object(envelope.error) ? envelope.error : undefined;
      throw new MachineLoginError(
        response.ok ? 502 : response.status,
        typeof error?.code === "string" ? error.code : undefined,
      );
    }
    return envelope.value;
  } finally {
    clearTimeout(timer);
  }
}
export const machineLoginApi: MachineLoginApi = {
  async status(run, signal) {
    const value = await request(run, signal);
    if (!object(value)) throw invalid();
    if (value.signedIn === true && value.resumed === true) return { signedIn: true, resumed: true };
    if (value.waiting === true && (value.harness === "claude" || value.harness === "codex"))
      return {
        waiting: true,
        harness: value.harness,
        login: value.login === null ? null : loginOf(value.login),
      };
    throw invalid();
  },
  async start(run, signal) {
    return loginOf(await request(run, signal, { action: "start" }));
  },
  async finish(run, loginId, code, signal) {
    const value = await request(run, signal, {
      action: "finish",
      loginId,
      ...(code ? { code } : {}),
    });
    if (object(value) && value.signedIn === false) return { signedIn: false };
    if (object(value) && value.signedIn === true && value.resumed === true) return { signedIn: true, resumed: true };
    throw invalid();
  },
  async cancel(run, loginId, signal) {
    const value = await request(run, signal, { action: "cancel", loginId });
    if (!object(value) || value.cancelled !== true) throw invalid();
  },
};
