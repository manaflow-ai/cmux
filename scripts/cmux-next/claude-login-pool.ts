/**
 * The real-Claude journey leg's login pool: the run tries each Claude login it was given, in order, and takes the
 * first one whose account still has quota, so one spent login no longer turns the leg into a skip.
 *
 * The candidates are CMUX_JOURNEY_CLAUDE_OAUTH_POOL (one setup-token per line), then CLAUDE_CODE_OAUTH_TOKEN (the
 * journey's own login, as the workflow passes it), then CLAUDE_CODE_OAUTH_TOKEN_FALLBACK (the repository's), each
 * once. Before the machine is made, every candidate up to the first usable one gets one tiny messages request
 * (max_tokens 1, the OAuth beta header, the way Claude Code signs in): a 429 is a spent login, a 401 or 403 a
 * login the API refuses, and anything else (network, 5xx, an answer this code does not know) is "unknown",
 * which the run still uses, as it did before the pool existed.
 *
 * probe.json and summary.md name the slot index and each candidate's answer, never a token.
 */

export type LoginProbeStatus = "ok" | "spent" | "invalid" | "unknown";
export type LoginProbe = { slot: number; status: LoginProbeStatus; reason: string };
export type LoginPick = {
  /** The chosen login, or null with no candidate usable (every one spent or refused). */
  login: string | null;
  /** The chosen login's 0-based index among the candidates; null with none. */
  slot: number | null;
  /** One entry per candidate that was asked, in order; the pick stops asking at the first usable one. */
  rotation: LoginProbe[];
  candidates: number;
  /** The soonest reset a spent login named (the API's unified reset, an ISO time), when every slot is out. */
  resetAt: string | null;
};

export const LOGIN_PREFLIGHT_URL = "https://api.anthropic.com/v1/messages";
export const LOGIN_PREFLIGHT_MODEL = "claude-haiku-5-5";
const PREFLIGHT_TIMEOUT_MS = 10_000;

/** The pool lines, then the journey's login, then the repository's: trimmed, non-empty, each once. */
export function claudeLoginCandidates(env: Record<string, string | undefined>, creds: Record<string, string | undefined> = {}): string[] {
  const raw = [
    ...String(env.CMUX_JOURNEY_CLAUDE_OAUTH_POOL ?? "").split(/[\r\n]+/),
    env.CLAUDE_CODE_OAUTH_TOKEN,
    creds.CLAUDE_CODE_OAUTH_TOKEN,
    env.CLAUDE_CODE_OAUTH_TOKEN_FALLBACK,
  ];
  const out: string[] = [];
  for (const value of raw) {
    const token = String(value ?? "").trim();
    if (token && !token.startsWith("#") && !out.includes(token)) out.push(token);
  }
  return out;
}

type HeaderBag = { get(name: string): string | null } | Record<string, string | undefined>;
function header(headers: HeaderBag | undefined, name: string): string | null {
  if (!headers) return null;
  if (typeof (headers as any).get === "function") return (headers as any).get(name);
  const bag = headers as Record<string, string | undefined>;
  const key = Object.keys(bag).find((k) => k.toLowerCase() === name);
  return key ? bag[key] ?? null : null;
}

/** The unified reset header as an ISO time (it is epoch seconds), or null. */
function resetIso(headers: HeaderBag | undefined): string | null {
  const raw = header(headers, "anthropic-ratelimit-unified-reset");
  const n = Number(raw);
  if (!raw || !Number.isFinite(n) || n <= 0) return null;
  return new Date(n * 1000).toISOString().replace(/\.\d+Z$/, "Z");
}

/** What one preflight answer says about the login. The reason is public: a status, a header word, never the body's token. */
export function classifyLoginProbe(status: number, headers?: HeaderBag, body?: unknown): { status: LoginProbeStatus; reason: string; resetAt: string | null } {
  const unified = header(headers, "anthropic-ratelimit-unified-status");
  const resetAt = resetIso(headers);
  const errorType = String((body as any)?.error?.type ?? "").replace(/[^\w.-]/g, "").slice(0, 40);
  if (status >= 200 && status < 300) {
    // A 200 can still say the window is spent for the next request ("rejected"): count only an allowed answer.
    if (unified === "rejected") return { status: "spent", reason: `HTTP ${status} unified=rejected${resetAt ? ` resets ${resetAt}` : ""}`, resetAt };
    return { status: "ok", reason: `HTTP ${status}${unified ? ` unified=${unified.replace(/[^\w.-]/g, "")}` : ""}`, resetAt: null };
  }
  if (status === 429) return { status: "spent", reason: `HTTP 429${unified ? ` unified=${unified.replace(/[^\w.-]/g, "")}` : ""}${resetAt ? ` resets ${resetAt}` : ""}`, resetAt };
  if (status === 401 || status === 403) return { status: "invalid", reason: `HTTP ${status}${errorType ? ` ${errorType}` : ""}`, resetAt: null };
  return { status: "unknown", reason: `HTTP ${status}${errorType ? ` ${errorType}` : ""}`, resetAt: null };
}

/** One preflight request for one login: never throws, never logs the token. */
export async function probeClaudeLogin(token: string, fetchFn: typeof fetch = globalThis.fetch, url = LOGIN_PREFLIGHT_URL): Promise<{ status: LoginProbeStatus; reason: string; resetAt: string | null }> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), PREFLIGHT_TIMEOUT_MS);
  try {
    const r = await fetchFn(url, {
      method: "POST",
      signal: abort.signal,
      headers: {
        authorization: `Bearer ${token}`,
        "anthropic-beta": "oauth-2025-04-20",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: LOGIN_PREFLIGHT_MODEL, max_tokens: 1, messages: [{ role: "user", content: "." }] }),
    });
    let body: unknown = null;
    try { body = await r.json(); } catch { /* the status says enough */ }
    return classifyLoginProbe(r.status, r.headers, body);
  } catch (error) {
    const name = abort.signal.aborted ? "timeout" : String((error as Error)?.name ?? "error").replace(/[^\w]/g, "");
    return { status: "unknown", reason: `no answer (${name})`, resetAt: null };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Asks each candidate in order and takes the first ok one; with none ok, the first unknown one (fail open, as a run
 * with one login did); with every one spent or refused, none.
 */
export async function pickClaudeLogin(candidates: string[], probe: (token: string) => Promise<{ status: LoginProbeStatus; reason: string; resetAt: string | null }>): Promise<LoginPick> {
  const rotation: LoginProbe[] = [];
  const resets: string[] = [];
  let firstUnknown: number | null = null;
  for (const [slot, token] of candidates.entries()) {
    const answer = await probe(token);
    rotation.push({ slot, status: answer.status, reason: answer.reason });
    if (answer.resetAt) resets.push(answer.resetAt);
    if (answer.status === "ok") return { login: token, slot, rotation, candidates: candidates.length, resetAt: null };
    if (answer.status === "unknown" && firstUnknown === null) firstUnknown = slot;
  }
  if (firstUnknown !== null) return { login: candidates[firstUnknown], slot: firstUnknown, rotation, candidates: candidates.length, resetAt: null };
  return { login: null, slot: null, rotation, candidates: candidates.length, resetAt: resets.sort()[0] ?? null };
}

/** "Nov 18, 3am" from an ISO time, the reset words Claude Code prints, which cmuxterm-hq's agent_quota reads. */
export function resetWords(iso: string | null): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const month = d.toLocaleString("en-US", { month: "short", timeZone: "UTC" });
  const h = d.getUTCHours();
  const m = d.getUTCMinutes();
  const hour = `${h % 12 === 0 ? 12 : h % 12}${m ? `:${String(m).padStart(2, "0")}` : ""}${h < 12 ? "am" : "pm"}`;
  return `${month} ${d.getUTCDate()}, ${hour}`;
}

/**
 * The failed login step's detail when every slot is spent. It starts with Claude Code's own limit words, which
 * cmuxterm-hq's cloud journey reconciler (cap.agent_quota) reads as a skipped run, not a product failure.
 */
export function allSpentDetail(pick: LoginPick): string {
  const words = resetWords(pick.resetAt);
  const refused = pick.rotation.filter((r) => r.status === "invalid").length;
  return `You've hit your usage limit${words ? ` · resets ${words} (UTC)` : ""}: infra: claude login spent (all ${pick.candidates} slots${refused ? `; ${refused} refused` : ""}); no machine was created`;
}

/** The summary line for the login rotation: slot and answers, no token. */
export function rotationLine(pick: LoginPick): string {
  const answers = pick.rotation.map((r) => `slot ${r.slot} ${r.status} (${r.reason})`).join("; ");
  return pick.slot === null ? `no usable slot of ${pick.candidates}: ${answers}` : `slot ${pick.slot} of ${pick.candidates}: ${answers}`;
}
