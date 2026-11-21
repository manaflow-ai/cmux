/**
 * Actors: one signed-in identity each (owner, admin, member, guest, outsider), with its own HOME, XDG folders and
 * control-socket path, so no two actors share a login, a cache or the person's running cmux. Every `cmux` call an
 * actor makes gets only this actor's environment (CMUX_CLOUD_API_URL, CMUX_CLOUD_ACCESS_TOKEN, CMUX_CLOUD_TEAM) on a
 * clean base: no CMUX_* variable of the caller (its socket, workspace or surface) leaks in.
 *
 * Two other kinds: `anon` (no account, no token: usage errors) and `app`, the person signed in to a tagged cmux app
 * (CMUX_TAG): its verbs go to that app's socket (team sessions, follow, reassign, copy link, transfer to this Mac) or
 * through this computer's link (`cmux link chat`), as that person, with the caller's HOME and nothing else of it.
 */
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, statSync } from "node:fs";
import path from "node:path";
import type { ActionResult, ActorSpec } from "./engine";

export type Identity = {
  email: string;
  /** cmux user id (user_<20 hex>), known after account.ensure. */
  user?: string;
  stack_user: string;
  access_token: string;
  refresh_token?: string;
};

/** The variables a clean child gets from the caller; everything else (CMUX_*, tokens, HOME) is the actor's own. */
const PASS_ENV = ["PATH", "LANG", "LC_ALL", "TMPDIR", "TERM", "USER", "LOGNAME", "SHELL", "TZ"];

/** A tagged cmux app this run may drive (the `app` actor): its control socket and the variables its CLI reads. */
export type AppTarget = { tag: string; socket: string; env: Record<string, string> };

/** The tag's slug, as scripts/cmux-debug-cli.sh makes it. */
export const tagSlug = (tag: string) => tag.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "agent";

/**
 * The tagged app's socket (scripts/cmux-debug-cli.sh: the state folder first, then the old /tmp name), or why none is
 * reachable. `ping` answers whether the app answers there (`cmux app ping`).
 */
export function findApp(tag: string | undefined, explicitSocket: string | undefined, home: string, ping: (t: AppTarget) => boolean): AppTarget | string {
  if (!tag && !explicitSocket) return "no tagged app: set CMUX_TAG=<tag> (and --cmux <that app's bin/cmux>) or --app-socket PATH";
  const slug = tagSlug(tag ?? "selftest");
  const candidates = explicitSocket ? [explicitSocket] : [path.join(home, ".local/state/cmux", `cmux-debug-${slug}.sock`), `/tmp/cmux-debug-${slug}.sock`];
  const socket = candidates.find((c) => {
    try {
      return statSync(c).isSocket();
    } catch {
      return false;
    }
  });
  if (!socket) return `no app socket for tag ${tag ?? "(none)"} at ${candidates.join(" or ")}: launch the tagged app`;
  const bundle = slug.replace(/-/g, ".");
  const target: AppTarget = { tag: slug, socket, env: { CMUX_SOCKET_PATH: socket, ...(tag ? { CMUX_TAG: slug, CMUX_BUNDLE_ID: `com.cmuxterm.app.debug.${bundle}` } : {}) } };
  return ping(target) ? target : `the app at ${socket} does not answer \`cmux app ping\``;
}

export class Actor {
  readonly home: string;
  identity: Identity | null = null;
  /** The shared team this actor acts in (x-cmux-team / CMUX_CLOUD_TEAM); null for its personal team. */
  team: string | null = null;
  /** For the `app` actor: the tagged app it drives (its own HOME is then the caller's, where the app's link lives). */
  app: AppTarget | null = null;
  constructor(readonly spec: ActorSpec, root: string, readonly api: string) {
    mkdirSync(root, { recursive: true });
    this.home = mkdtempSync(path.join(root, `${spec.name}-`));
    for (const d of [".config", ".local/state", ".cache"]) mkdirSync(path.join(this.home, d), { recursive: true });
  }
  get name(): string {
    return this.spec.name;
  }
  /** The control socket path this actor's CLI would use: nothing listens there, so an app-only verb fails fast. */
  get socket(): string {
    return path.join(this.home, "cmux.sock");
  }
  env(base: NodeJS.ProcessEnv = process.env, extra: Record<string, string> = {}): Record<string, string> {
    const out: Record<string, string> = {};
    for (const k of PASS_ENV) if (base[k]) out[k] = base[k]!;
    if (this.app) {
      // The person's app and link: the caller's HOME (the link's registration lives there), the tag's socket; no token.
      for (const k of ["HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"]) if (base[k]) out[k] = base[k]!;
      return { ...out, ...this.app.env, CMUX_SELFTEST_ACTOR: this.name, ...extra };
    }
    Object.assign(out, {
      HOME: this.home,
      XDG_CONFIG_HOME: path.join(this.home, ".config"),
      XDG_STATE_HOME: path.join(this.home, ".local/state"),
      XDG_CACHE_HOME: path.join(this.home, ".cache"),
      CMUX_SOCKET_PATH: this.socket,
      CMUX_CLOUD_API_URL: this.api,
      CMUX_SELFTEST_ACTOR: this.name,
    });
    if (this.identity) out.CMUX_CLOUD_ACCESS_TOKEN = this.identity.access_token;
    if (this.team) out.CMUX_CLOUD_TEAM = this.team;
    return { ...out, ...extra };
  }
  headers(opts: { team?: string | null; token?: string } = {}): Record<string, string> {
    const token = opts.token ?? this.identity?.access_token;
    const team = opts.team === undefined ? this.team : opts.team;
    return { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(team ? { "x-cmux-team": team } : {}) };
  }
  /** One backend route as this actor, as an ActionResult (transport api). */
  async request(method: string, route: string, body?: unknown, opts: { team?: string | null; token?: string; timeoutMs?: number; fetcher?: typeof fetch } = {}): Promise<ActionResult> {
    const f = opts.fetcher ?? fetch;
    let res: Response;
    try {
      res = await f(`${this.api}${route}`, {
        method,
        headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...this.headers(opts) },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(opts.timeoutMs ?? 60_000),
      });
    } catch (e) {
      return { ok: false, code: "network.unreachable", message: String((e as Error).message ?? e), json: null, transport: "api" };
    }
    return apiResult(res.status, await res.text());
  }
  op(op: string, params: unknown, key?: string, opts: { team?: string | null; token?: string } = {}): Promise<ActionResult> {
    return this.request("POST", "/v1/ops", { op, params, ...(key ? { idempotency_key: key } : {}) }, opts).then(unwrap);
  }
  read(op: string, params: unknown, opts: { team?: string | null; token?: string } = {}): Promise<ActionResult> {
    return this.request("POST", "/v1/read", { op, params }, opts).then(unwrap);
  }
}

/** A route's answer: `{ok:false, error:{code}}` and non-2xx are failures with the code; else the body. */
export function apiResult(status: number, text: string): ActionResult {
  let json: any;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text.slice(0, 300) };
  }
  // `{error: {code}}`, `{ok:false, value:{error}}`, or a tagged error with its code at the top (the auth layer).
  const error = json?.error ?? json?.value?.error ?? (status >= 400 && typeof json?.code === "string" ? json : undefined);
  if (status < 200 || status >= 300 || json?.ok === false) {
    const code = typeof error?.code === "string" ? error.code : typeof error === "string" ? error : `http.${status}`;
    return { ok: false, code, message: typeof error?.message === "string" ? error.message : `HTTP ${status}`, json, transport: "api" };
  }
  return { ok: true, json, transport: "api" };
}

/** /v1/ops and /v1/read answer {ok, value}: the value is the JSON a step matches. */
const unwrap = (r: ActionResult): ActionResult => (r.ok && r.json && "value" in r.json ? { ...r, json: r.json.value } : r);

/** The JSON a `--json` verb printed: the whole stdout, else its last line that parses. */
export function cliJson(stdout: string): any {
  const text = stdout.trim();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    for (const line of text.split("\n").reverse()) {
      try {
        return JSON.parse(line);
      } catch {
        /* not this line */
      }
    }
  }
  return null;
}

/**
 * A verb's stable error code: the JSON's error.code (or code), else a `code: message` / `error[code]` the CLI printed
 * on stderr, else `cli.exit_N`.
 */
export function cliErrorCode(json: any, stderr: string, exit: number): string {
  const e = json?.error ?? json?.result?.error;
  if (typeof e?.code === "string") return e.code;
  if (typeof json?.code === "string" && json?.ok === false) return json.code;
  // `cmux link chat` and `cmux link dial`: {"ok":false,"error_code":CODE,"error":MESSAGE}.
  if (typeof json?.error_code === "string") return json.error_code;
  // A local refusal with --json: one JSON object on stderr ({code, message} or {error: {code}}).
  const err = cliJson(stderr);
  for (const c of [err?.code, err?.error?.code, err?.error_code]) if (typeof c === "string" && c) return c;
  const m = /\b([a-z][a-z0-9_]*\.[a-z0-9_.]+)\b/.exec(stderr);
  if (m) return m[1]!;
  return `cli.exit_${exit}`;
}

/** Run `cmux ARGV` as the actor, async (so steps may run at once), with a deadline. */
export function runCli(cmux: string, actor: Actor, argv: string[], timeoutMs = 120_000, extraEnv: Record<string, string> = {}): Promise<ActionResult> {
  return new Promise((resolve) => {
    const child = spawn(cmux, argv, { env: actor.env(process.env, extraEnv), stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (c: string) => (stdout += c));
    child.stderr.setEncoding("utf8").on("data", (c: string) => (stderr += c));
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, code: "cli.not_runnable", message: e.message, json: null, transport: "cli", argv });
    });
    child.on("close", (exit, signal) => {
      clearTimeout(timer);
      let json = cliJson(stdout);
      if (json && typeof json === "object" && "result" in json && json.ok !== false) json = json.result ?? json;
      const failed = exit !== 0 || json?.ok === false || (json?.error && typeof json.error === "object");
      if (signal) return resolve({ ok: false, code: "cli.timeout", message: `killed after ${timeoutMs} ms`, json, transport: "cli", argv });
      if (failed) {
        const message = typeof json?.error === "string" ? json.error : (json?.error?.message ?? cliJson(stderr)?.message ?? stderr.trim().split("\n").pop() ?? "");
        return resolve({ ok: false, code: cliErrorCode(json, stderr, exit ?? 1), message: String(message).slice(0, 400), json, transport: "cli", argv });
      }
      resolve({ ok: true, json: json ?? { stdout: stdout.slice(-2000) }, transport: "cli", argv });
    });
  });
}

/**
 * Whether a `--help` text is the verb's own: it names `cmux WORDS` (or `cmux vm REST` for a `cloud` verb, its alias)
 * as a whole command. An unknown verb gets its noun's overview, which exits 0 too, so the exit code proves nothing.
 */
export function helpNamesVerb(text: string, words: string[]): boolean {
  if (/unknown (command|verb|subcommand)|no such (command|verb)|unrecognized/i.test(text)) return false;
  const names = [`cmux ${words.join(" ")}`, ...(words[0] === "cloud" ? [`cmux vm ${words.slice(1).join(" ")}`] : [])];
  const esc = (x: string) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return names.some((n) => new RegExp(`${esc(n)}(?=\\s|$|\\])`, "m").test(text));
}

const verbCache = new Map<string, boolean>();
/**
 * Whether this cmux has the verb: `cmux WORDS --help` exits 0 with a clean environment (no app socket, so an app verb's
 * help still answers from the CLI's own catalog). Cached per binary and words.
 */
export function verbExists(cmux: string, words: string[]): boolean {
  const key = `${cmux}\0${words.join(" ")}`;
  const hit = verbCache.get(key);
  if (hit !== undefined) return hit;
  const done = spawnSync(cmux, [...words, "--help"], { env: { PATH: process.env.PATH ?? "", HOME: process.env.TMPDIR ?? "/tmp", CMUX_SOCKET_PATH: "/nonexistent/cmux-selftest.sock" }, encoding: "utf8", timeout: 15_000 });
  const text = `${done.stdout ?? ""}\n${done.stderr ?? ""}`;
  const ok = helpNamesVerb(text, words);
  verbCache.set(key, ok);
  return ok;
}
