#!/usr/bin/env bun
/**
 * Auto mode's real journey against staging: one chat goes Mac -> Cloud -> Mac (.github/workflows/auto-journey.yml).
 *
 * The script is the FakeAutoCloud journey (cmux-tui/crates/acpmux/tests/auto_journey, `journey.rs` and `steps.rs`)
 * run on real pieces: this Mac's acpmux daemon, built from the dispatched commit, is the laptop; a fresh Cloud
 * machine of the agent test account is the Auto machine; the store is staging's /v1/auto-sessions
 * (backend/apps/api/src/auto-sessions/routes.ts). The person's moves are the owner's routes, as the app's banner
 * sends them.
 *
 *   1. sign in        Stack password sign-in as the agent test account; a `cli` install of its own, whose token the
 *                     daemon gets the way it gets the app's (`cmux --json auth token`, a stub that mints it here).
 *   2. store          GET /v1/auto-sessions answers (a 404 is a stack with no AUTO_SESSION_DO bound).
 *   3. machine        a new Cloud machine for this run, running, and the owner's Auto machine
 *                     (GET/PUT /v1/auto-sessions/machine). The same stand-in harness is installed on it.
 *   4. Mac daemon     `cmux-tui acp daemon run` in a fresh HOME with AutoCloud's switch `cloud.autoCloud` on (this
 *                     run's settings file only: the test account on this ephemeral VM), the stand-in harness, and
 *                     the install's sign-in.
 *   5. chat on Mac    a checkout with a local commit and uncommitted work; `session/new`, Auto on
 *                     (`_acpmux/auto_session/set`), a prompt answered on the Mac; the store holds it as
 *                     `device:<id>` with a snapshot that covers its last event.
 *   6. to the Cloud   POST /v1/auto-sessions/:id/move {to: "cloud"}; the holder becomes `vm:<machine>`; the machine's
 *                     folder has the Mac's commit and uncommitted work; a message sent to the chat
 *                     (POST /v1/auto-sessions/:id/inbox) is answered by the harness on the machine.
 *   7. back home      POST /v1/auto-sessions/:id/move {to: "local", device}; the holder becomes `device:<id>`; the
 *                     Mac's folder has the machine's file change; the Mac's transcript (`session/load`) has the
 *                     Mac's prompt and the Cloud's, once each; the next prompt runs on the Mac.
 *
 * The stand-in harness is acpmux's own `cli-agent` over a shell script that answers `side=mac` or `side=vm` and
 * writes one line to `auto-journey-ran.txt` in the chat's folder: it needs no model login on either side, and its
 * answer says where the turn ran.
 *
 * Writes OUT/auto-journey.json (steps) and OUT/summary.md; never a token. The machine and the install are removed
 * at the end (also by `--cleanup` from an always() step).
 *
 *   bun scripts/cmux-next/auto-journey.ts --backend staging --cmux PATH/cmux-tui --out DIR
 *   bun scripts/cmux-next/auto-journey.ts --mint-token STATE_FILE     (the daemon's `cmux --json auth token`)
 *   bun scripts/cmux-next/auto-journey.ts --backend staging --cleanup DIR
 */
import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Api, CHAT_START_SIZE, STACK, directExec, http, passwordSignIn, resolveBackend, scrub, sleep, waitMachine } from "./cloud-journey.ts";

type Step = { step: string; status: "pass" | "fail" | "skip"; ms: number; detail: string };
type View = { id: string; holder: string; epoch: number; version: number; lastSeq: number; snapshot: number; standby: string[]; auto: boolean; move?: unknown };

const MOVE_BUDGET_MS = 6 * 60_000;
const TURN_BUDGET_MS = 4 * 60_000;
const HARNESS = "auto-journey";
const RAN_FILE = "auto-journey-ran.txt";

const argValue = (name: string, argv = process.argv): string | undefined => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);
/** The guest's shell prelude (cloud-journey.ts GUEST): HOME, and `$c` the guest's cmux-tui. */
const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; c="$(command -v "$c" || echo "$c")"; ';

/** The stand-in agent: answers where it ran and leaves a line in the chat's folder. */
const agentScript = (side: "mac" | "vm") => `#!/bin/sh
p="$(cat | tr '\\n' ' ' | cut -c1-200)"
printf '%s\\n' "side=${side} prompt=$p" >> ${RAN_FILE}
echo "AUTO_JOURNEY_REPLY side=${side} prompt=$p"
`;
const harnessProfile = (cmuxTui: string, script: string) =>
  `protocol = "acp"\ncommand = ${JSON.stringify(cmuxTui)}\nargs = ["acp", "cli-agent", "--", ${JSON.stringify(script)}]\n`;

// ---------------------------------------------------------------- the install's token, for the Mac daemon

type InstallState = { api: string; user: string; install: string; jwk: JsonWebKey; team?: string };

async function mintInstallToken(state: InstallState): Promise<{ access_token: string; expires_in?: number }> {
  const key = await crypto.subtle.importKey("jwk", state.jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const ch = await http("POST", `${state.api}/v1/auth/challenge`, { user: state.user, install: state.install }, {});
  if (ch.status !== 200) throw new Error(`challenge HTTP ${ch.status} ${short(ch.body)}`);
  const message = new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`);
  const signature = Buffer.from(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, message))).toString("base64url");
  const tok = await http("POST", `${state.api}/v1/auth/token`, { user: state.user, install: state.install, nonce: ch.body.nonce, signature }, {});
  if (tok.status !== 200 || typeof tok.body.access_token !== "string") throw new Error(`token HTTP ${tok.status} ${short(tok.body?.error ?? tok.body)}`);
  return { access_token: tok.body.access_token, expires_in: typeof tok.body.expires_in === "number" ? tok.body.expires_in : undefined };
}

/** `--mint-token STATE`: what `cmux --json auth token` prints for the daemon's sign-in (laptop/sign_in.rs). */
async function mintMode(stateFile: string): Promise<number> {
  const state = JSON.parse(readFileSync(stateFile, "utf8")) as InstallState;
  const t = await mintInstallToken(state);
  process.stdout.write(JSON.stringify({ access_token: t.access_token, expires_in: t.expires_in ?? 600, api_origin: state.api, team: state.team ?? null }));
  return 0;
}

// ---------------------------------------------------------------- the Mac daemon's socket (ACP + acpmux methods)

class Socket {
  private buf = "";
  private next = 1;
  private waiting = new Map<number, { ok: (v: any) => void; err: (e: Error) => void }>();
  readonly notes: any[] = [];
  private constructor(private conn: net.Socket) {
    conn.setEncoding("utf8");
    conn.on("data", (chunk: string) => {
      this.buf += chunk;
      for (let nl = this.buf.indexOf("\n"); nl >= 0; nl = this.buf.indexOf("\n")) {
        const line = this.buf.slice(0, nl).trim();
        this.buf = this.buf.slice(nl + 1);
        if (!line) continue;
        let msg: any;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id !== undefined && this.waiting.has(msg.id) && (msg.result !== undefined || msg.error !== undefined)) {
          const w = this.waiting.get(msg.id)!;
          this.waiting.delete(msg.id);
          if (msg.error) w.err(new Error(`${msg.error.code}: ${msg.error.message}`));
          else w.ok(msg.result);
        } else if (msg.method) {
          this.notes.push(msg);
          // A permission request: the stand-in never asks, but a request left unanswered would hang the turn.
          if (msg.id !== undefined && msg.method === "session/request_permission") {
            const allow = (msg.params?.options ?? []).find((o: any) => /allow/.test(String(o.kind ?? "")))?.optionId;
            conn.write(`${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { outcome: allow ? { outcome: "selected", optionId: allow } : { outcome: "cancelled" } } })}\n`);
          }
        }
      }
    });
    conn.on("close", () => { for (const w of this.waiting.values()) w.err(new Error("the daemon's socket closed")); this.waiting.clear(); });
  }
  static open(socketPath: string): Promise<Socket> {
    return new Promise((ok, err) => {
      const c = net.createConnection(socketPath);
      c.once("connect", () => ok(new Socket(c)));
      c.once("error", err);
    });
  }
  call(method: string, params: unknown, timeoutMs = 60_000): Promise<any> {
    const id = this.next++;
    return new Promise((ok, err) => {
      const timer = setTimeout(() => { this.waiting.delete(id); err(new Error(`${method}: no answer in ${timeoutMs} ms`)); }, timeoutMs);
      this.waiting.set(id, { ok: (v) => { clearTimeout(timer); ok(v); }, err: (e) => { clearTimeout(timer); err(e); } });
      this.conn.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }
  close() { this.conn.destroy(); }
}

/** The text of every agent_message_chunk and user_message_chunk the socket saw for `session` since `from`. */
function transcript(notes: any[], session: string, from = 0): { user: string[]; agent: string } {
  const user: string[] = [];
  let agent = "";
  for (const n of notes.slice(from)) {
    if (n.method !== "session/update" || n.params?.sessionId !== session) continue;
    const u = n.params.update ?? {};
    const text = typeof u.content?.text === "string" ? u.content.text : "";
    if (u.sessionUpdate === "user_message_chunk") user.push(text);
    if (u.sessionUpdate === "agent_message_chunk") agent += text;
  }
  return { user, agent };
}

// ---------------------------------------------------------------- the journey

class Journey {
  readonly steps: Step[] = [];
  readonly secrets: string[] = [];
  constructor(readonly out: string) {}
  async step<T>(name: string, run: () => Promise<{ value: T; detail: string }>): Promise<T> {
    const t0 = Date.now();
    try {
      const r = await run();
      this.record({ step: name, status: "pass", ms: Date.now() - t0, detail: r.detail });
      return r.value;
    } catch (e) {
      this.record({ step: name, status: "fail", ms: Date.now() - t0, detail: String((e as Error)?.message ?? e) });
      throw e;
    }
  }
  record(s: Step) {
    s.detail = scrub(s.detail, this.secrets).slice(0, 600);
    this.steps.push(s);
    console.log(JSON.stringify(s));
  }
  write(meta: Record<string, string>) {
    writeFileSync(path.join(this.out, "auto-journey.json"), JSON.stringify({ meta, steps: this.steps }, null, 2));
    const rows = this.steps.map((s) => `| ${s.status === "pass" ? "pass" : s.status} | ${s.step} | ${(s.ms / 1000).toFixed(1)} s | ${s.detail.replace(/\|/g, "\\|").replace(/\n/g, " ")} |`);
    writeFileSync(path.join(this.out, "summary.md"), [
      "| | step | time | detail |", "|---|---|---|---|", ...rows, "",
      ...Object.entries(meta).map(([k, v]) => `- ${k}: \`${v}\``), "",
    ].join("\n"));
  }
}

async function main(): Promise<number> {
  const minting = argValue("--mint-token", process.argv);
  if (minting) return mintMode(minting);
  const backend = resolveBackend(argValue("--backend", process.argv) ?? "staging");
  if (backend.name !== "staging") throw new Error(`auto-journey runs against staging only (got ${backend.name})`);
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account)");
  const cleanupDir = argValue("--cleanup", process.argv);
  if (cleanupDir) return cleanupMode(backend.api, backend.stack, email, password, cleanupDir);
  const cmuxTui = path.resolve(argValue("--cmux", process.argv) ?? "");
  if (!existsSync(cmuxTui)) throw new Error("--cmux PATH: this commit's cmux-tui");
  const out = path.resolve(argValue("--out", process.argv) ?? "auto-journey-out");
  mkdirSync(out, { recursive: true });

  const J = new Journey(out);
  J.secrets.push(password);
  const tag = `aj-${Date.now().toString(36)}`;
  const meta: Record<string, string> = { tag, api: backend.api };
  const owned: { machine?: string; install?: string } = {};
  writeFileSync(path.join(out, "owned.json"), JSON.stringify(owned));
  const keep = () => writeFileSync(path.join(out, "owned.json"), JSON.stringify(owned));
  const api = new Api(backend.api);
  let daemon: ChildProcess | null = null;
  let sock: Socket | null = null;
  const store = async (method: string, route: string, body?: unknown, timeoutMs = 30_000) => {
    const r = await http(method, `${backend.api}/v1/auto-sessions${route}`, body, { authorization: `Bearer ${api.bearer}` }, timeoutMs, method === "GET");
    return r;
  };
  const view = async (id: string): Promise<View> => {
    const r = await store("GET", `/${encodeURIComponent(id)}`);
    if (r.status !== 200) throw new Error(`GET /v1/auto-sessions/${id}: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
    return r.body.session as View;
  };
  /** The store's own long poll (`/wait`, at most 25 s a call) until `want`, or the budget. */
  const until = async (id: string, what: string, want: (v: View) => boolean, budgetMs = MOVE_BUDGET_MS): Promise<View> => {
    const deadline = Date.now() + budgetMs;
    let v = await view(id);
    while (!want(v)) {
      if (Date.now() > deadline) throw new Error(`${what}: not in ${budgetMs / 1000} s; the store has holder ${v.holder} epoch ${v.epoch} lastSeq ${v.lastSeq} snapshot ${v.snapshot} standby ${v.standby.join(",") || "none"} move ${short(v.move)}`);
      const r = await store("GET", `/${encodeURIComponent(id)}/wait?after=${v.version}&timeoutMs=20000`, undefined, 30_000);
      v = r.status === 200 ? (r.body.session as View) : (await sleep(2000), await view(id));
    }
    return v;
  };
  const events = async (id: string): Promise<Array<{ seq: number; record: any }>> => {
    const all: Array<{ seq: number; record: any }> = [];
    for (let after = 0; ;) {
      const r = await store("GET", `/${encodeURIComponent(id)}/events?after=${after}`);
      if (r.status !== 200) throw new Error(`events: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      all.push(...r.body.events);
      if (!r.body.events.length || r.body.events.at(-1).seq >= r.body.lastSeq) return all;
      after = r.body.events.at(-1).seq;
    }
  };

  try {
    // 1. Sign in, and an install of this run's own for the Mac daemon.
    const s = await J.step("sign in (Stack password, agent test account)", async () => {
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      api.bearer = s.access;
      return { value: s, detail: `Stack project ${STACK[backend.stack].project.slice(0, 8)}` };
    });
    void s;
    const installState = await J.step("cli install for the Mac daemon", async () => {
      const user = await api.op("user.ensure", {}, `${tag}-ensure`);
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
      const pub = await crypto.subtle.exportKey("jwk", pair.publicKey);
      const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: pub.x, y: pub.y }, kind: "cli", name: `auto journey ${tag}`, device_name: "auto journey", platform: "macos" }, `${tag}-install`);
      owned.install = inst.id;
      keep();
      const state: InstallState = { api: backend.api, user: inst.user ?? user.id ?? user.user?.id, install: inst.id, jwk: await crypto.subtle.exportKey("jwk", pair.privateKey), ...(typeof inst.team === "string" ? { team: inst.team } : {}) };
      const t = await mintInstallToken(state);
      J.secrets.push(t.access_token);
      return { value: state, detail: `install ${inst.id} (kind cli); its token mints` };
    });

    // 2. The store.
    await J.step("store answers (GET /v1/auto-sessions)", async () => {
      const r = await store("GET", "?limit=1");
      if (r.status === 404) throw new Error("HTTP 404: the staging API has no Auto store bound (AUTO_SESSION_DO), or it runs a build older than the Auto routes");
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      return { value: null, detail: `${r.body.sessions?.length ?? 0} session(s) on the first page` };
    });

    // 3. A Cloud machine of this run's own, as the owner's Auto machine, with the stand-in harness.
    const machine = await J.step("Cloud machine for this run (create, running)", async () => {
      const v = await api.op("cloud.machine.create", { name: `auto journey ${tag}`, size: CHAT_START_SIZE }, `${tag}-create`);
      owned.machine = v.machine.id as string;
      keep();
      const m = await waitMachine(api, owned.machine, (x) => x.status === "running" && Boolean(x.host), 300_000);
      return { value: owned.machine, detail: `${owned.machine} running, daemon ${m.image?.daemon_version ?? "?"}` };
    });
    meta.machine = machine;
    await J.step("the run's machine is the owner's Auto machine (/v1/auto-sessions/machine)", async () => {
      let r = await store("GET", "/machine");
      if (r.status !== 200) throw new Error(`GET: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      if (r.body.machine !== machine) {
        const put = await store("PUT", "/machine", { team: r.body.team, machine });
        if (put.status !== 200) throw new Error(`PUT {team ${r.body.team}, machine ${machine}}: HTTP ${put.status} ${short(put.body?.error ?? put.body)}`);
        r = await store("GET", "/machine");
      }
      if (r.body.machine !== machine) throw new Error(`the store picks ${r.body.machine}, not ${machine}`);
      meta.team = String(r.body.team);
      return { value: null, detail: `team ${r.body.team}, machine ${machine}` };
    });
    const exec = directExec(api, machine, J);
    await J.step("stand-in harness on the machine", async () => {
      const script = "$HOME/.cmux/auto-journey-agent.sh";
      const cmd = `${GUEST}set -e; mkdir -p "$HOME/.config/cmux/harnesses"; cat > "${script}" <<'AJ_AGENT'\n${agentScript("vm")}AJ_AGENT\nchmod 755 "${script}"; ` +
        `printf '%s\\n' 'protocol = "acp"' "command = \\"$c\\"" "args = [\\"acp\\", \\"cli-agent\\", \\"--\\", \\"${script.replace("$HOME", "'\"$HOME\"'")}\\"]" > "$HOME/.config/cmux/harnesses/${HARNESS}.toml"; ` +
        `"$c" acp daemon reload >/dev/null 2>&1 || true; "$c" --version 2>/dev/null | head -1; echo "@@ok"`;
      const r = await exec(cmd, 120_000);
      if (!/@@ok/.test(r.stdout)) throw new Error(`exit ${r.code}: ${(r.stdout + r.stderr).slice(-400)}`);
      return { value: null, detail: `${HARNESS} profile written; guest ${r.stdout.replace("@@ok", "").trim().slice(0, 120)}` };
    });

    // 4. The Mac daemon: a fresh HOME, AutoCloud on, the stand-in harness, the install's sign-in.
    const home = path.join(out, "home");
    const socketPath = path.join(os.tmpdir(), `aj-${process.pid}.sock`);
    const env: Record<string, string> = { ...(process.env as Record<string, string>) };
    for (const k of ["CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"]) delete env[k];
    const work = path.join(home, "work");
    await J.step("Mac daemon (cloud.autoCloud on, this run's HOME)", async () => {
      mkdirSync(path.join(home, ".config", "cmux", "harnesses"), { recursive: true });
      const settings = path.join(home, ".config", "cmux", "cmux-next.json");
      writeFileSync(settings, JSON.stringify({ cloud: { autoCloud: true } }, null, 2));
      const script = path.join(home, "auto-journey-agent.sh");
      writeFileSync(script, agentScript("mac"));
      chmodSync(script, 0o755);
      writeFileSync(path.join(home, ".config", "cmux", "harnesses", `${HARNESS}.toml`), harnessProfile(cmuxTui, script));
      const state = path.join(out, "install-state.json");
      writeFileSync(state, JSON.stringify(installState), { mode: 0o600 });
      const stub = path.join(home, "bin", "cmux");
      mkdirSync(path.dirname(stub), { recursive: true });
      writeFileSync(stub, `#!/bin/sh\n# The app's \`cmux --json auth token\`, for this run's install.\n[ "$1 $2 $3" = "--json auth token" ] || exit 2\nexec ${shq(process.execPath)} ${shq(fileURLToPath(import.meta.url))} --mint-token ${shq(state)}\n`);
      chmodSync(stub, 0o755);
      Object.assign(env, { HOME: home, CMUX_BIN: stub, CMUX_NEXT_CONFIG_FILE: settings, ACPMUX_SOCKET: socketPath, PATH: `${path.dirname(stub)}:${env.PATH ?? "/usr/bin:/bin"}` });
      delete env.ACPMUX_HOME;
      const log = path.join(out, "daemon.log");
      writeFileSync(log, "");
      const fd = (await import("node:fs")).openSync(log, "a");
      daemon = spawn(cmuxTui, ["acp", "daemon", "run"], { env, stdio: ["ignore", fd, fd], detached: false });
      const deadline = Date.now() + 120_000;
      while (!existsSync(socketPath)) {
        if (daemon.exitCode !== null) throw new Error(`the daemon exited ${daemon.exitCode}: ${readFileSync(log, "utf8").slice(-400)}`);
        if (Date.now() > deadline) throw new Error(`no socket at ${socketPath} in 120 s`);
        await sleep(250);
      }
      sock = await Socket.open(socketPath);
      await sock.call("initialize", { protocolVersion: 1, clientCapabilities: {} });
      return { value: null, detail: `pid ${daemon.pid}, socket up` };
    });
    const S = sock as unknown as Socket;

    // 5. A chat on the Mac with Auto on, a turn answered here, copied to the store.
    const id = await J.step("chat on the Mac with Auto on", async () => {
      const git = (args: string[], cwd = work) => {
        const r = Bun.spawnSync(["git", "-c", "user.name=Auto Journey", "-c", "user.email=auto-journey@example.com", "-c", "commit.gpgsign=false", ...args], { cwd, env });
        if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString().slice(-300)}`);
        return r.stdout.toString().trim();
      };
      git(["clone", "--quiet", "--depth", "5", "https://github.com/octocat/Hello-World.git", work], home);
      writeFileSync(path.join(work, "local.txt"), "a local commit\n");
      git(["add", "local.txt"]);
      git(["commit", "--quiet", "-m", "auto journey local commit"]);
      writeFileSync(path.join(work, "uncommitted.txt"), "uncommitted on the Mac\n");
      meta.mac_head = git(["rev-parse", "HEAD"]);
      const created = await S.call("session/new", { cwd: work, mcpServers: [], _meta: { acpmux: { harness: HARNESS, policy: "approve-all" } } });
      const sid = String(created.sessionId);
      const set = await S.call("_acpmux/auto_session/set", { sessionId: sid, auto: true });
      if (set?.autoSession?.auto !== true) throw new Error(`Auto did not go on: ${short(set)}`);
      return { value: sid, detail: `${sid}; row ${short(set.autoSession)}` };
    });
    meta.chat = id;
    const device = await J.step("the store holds it as this Mac (device:<id>, a snapshot)", async () => {
      const v = await until(id, "registered and copied", (v) => v.holder.startsWith("device:") && v.snapshot >= 1);
      return { value: v.holder, detail: `holder ${v.holder} epoch ${v.epoch} snapshot ${v.snapshot}` };
    });
    meta.device = device;
    await J.step("a turn on the Mac", async () => {
      const mark = S.notes.length;
      const r = await S.call("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "mac-1" }] }, TURN_BUDGET_MS);
      const t = transcript(S.notes, id, mark);
      if (!/side=mac prompt=mac-1/.test(t.agent)) throw new Error(`the reply was not the Mac's: ${short(t.agent)} (stop ${r?.stopReason})`);
      const v = await until(id, "the turn's copy reaches the store", (v) => v.holder === device && v.lastSeq > 0, TURN_BUDGET_MS);
      return { value: null, detail: `answered side=mac; store lastSeq ${v.lastSeq}` };
    });

    // 6. To the Cloud, and a turn there.
    await J.step("move to the Cloud (POST move {to: cloud})", async () => {
      const r = await store("POST", `/${encodeURIComponent(id)}/move`, { to: "cloud" });
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      return { value: null, detail: `wish ${short(r.body.session?.move)} keepInCloud ${r.body.session?.keepInCloud}` };
    });
    const inCloud = await J.step("holder becomes vm:<machine>", async () => {
      const v = await until(id, "the chat moves to the Cloud", (v) => v.holder === `vm:${machine}`);
      if (!v.standby.includes(device)) console.log(`note: the Mac is not listed standby yet (${v.standby.join(",") || "none"})`);
      return { value: v, detail: `holder ${v.holder} epoch ${v.epoch} standby ${v.standby.join(",") || "none"}` };
    });
    await J.step("the machine's folder has the Mac's commit and uncommitted work", async () => {
      const deadline = Date.now() + TURN_BUDGET_MS;
      for (;;) {
        const r = await exec(`${GUEST}d="$HOME/Projects/auto/${id}"; [ -d "$d" ] || { echo "@@missing"; exit 0; }; git -C "$d" rev-parse HEAD; cat "$d/local.txt" "$d/uncommitted.txt" "$d/${RAN_FILE}" 2>&1; echo "@@done"`, 60_000);
        if (/@@done/.test(r.stdout)) {
          const o = r.stdout;
          for (const want of [meta.mac_head, "a local commit", "uncommitted on the Mac", "side=mac prompt=mac-1"]) if (!o.includes(want)) throw new Error(`the machine's folder lacks ${JSON.stringify(want)}: ${o.slice(-400)}`);
          return { value: null, detail: `~/Projects/auto/${id} at ${meta.mac_head.slice(0, 12)} with the uncommitted file and the Mac's line` };
        }
        if (Date.now() > deadline) throw new Error(`no folder for the chat on the machine: ${(r.stdout + r.stderr).slice(-300)}`);
        await sleep(5000);
      }
    });
    await J.step("the chat runs on the machine (inbox message answered side=vm)", async () => {
      const posted = await store("POST", `/${encodeURIComponent(id)}/inbox`, { id: `${tag}-cloud-1`, text: "cloud-1" });
      if (posted.status !== 200) throw new Error(`inbox: HTTP ${posted.status} ${short(posted.body?.error ?? posted.body)}`);
      const deadline = Date.now() + TURN_BUDGET_MS;
      for (;;) {
        const all = await events(id);
        const text = all.filter((e) => e.seq > inCloud.lastSeq).map((e) => JSON.stringify(e.record)).join("\n");
        if (/side=vm prompt=cloud-1/.test(text) && /turn_result/.test(text)) {
          if (/side=mac prompt=cloud-1/.test(text)) throw new Error("the Mac answered the Cloud's message too");
          const v = await view(id);
          if (v.holder !== `vm:${machine}`) throw new Error(`holder moved during the turn: ${v.holder}`);
          return { value: null, detail: `delivery ${posted.body.state}; answered side=vm through seq ${all.at(-1)?.seq}` };
        }
        if (Date.now() > deadline) throw new Error(`no side=vm answer in the store's events after seq ${inCloud.lastSeq}: ${text.slice(-400)}`);
        await sleep(3000);
      }
    });

    // 7. Back home.
    await J.step("move back (POST move {to: local, device})", async () => {
      await until(id, "the Mac stands by", (v) => v.standby.includes(device), TURN_BUDGET_MS);
      const r = await store("POST", `/${encodeURIComponent(id)}/move`, { to: "local", device });
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      return { value: null, detail: `wish ${short(r.body.session?.move)}` };
    });
    await J.step("holder becomes device:<id>", async () => {
      const v = await until(id, "the chat comes home", (v) => v.holder === device && v.epoch > inCloud.epoch);
      return { value: null, detail: `holder ${v.holder} epoch ${v.epoch}` };
    });
    await J.step("files intact on the Mac", async () => {
      const deadline = Date.now() + TURN_BUDGET_MS;
      for (;;) {
        const ran = existsSync(path.join(work, RAN_FILE)) ? readFileSync(path.join(work, RAN_FILE), "utf8") : "";
        if (ran.includes("side=vm prompt=cloud-1")) {
          for (const f of ["local.txt", "uncommitted.txt"]) if (!existsSync(path.join(work, f))) throw new Error(`${f} is gone from the Mac's folder`);
          if (!ran.includes("side=mac prompt=mac-1")) throw new Error(`the Mac's own line is gone: ${ran}`);
          return { value: null, detail: `${RAN_FILE} has the Mac's line and the machine's; local.txt and uncommitted.txt kept` };
        }
        if (Date.now() > deadline) throw new Error(`the machine's change never reached the Mac's folder: ${JSON.stringify(ran)}`);
        await sleep(3000);
      }
    });
    await J.step("transcript intact on the Mac (session/load)", async () => {
      const mark = S.notes.length;
      await S.call("session/load", { sessionId: id, cwd: work, mcpServers: [] }, 60_000);
      await sleep(1000);
      const t = transcript(S.notes, id, mark);
      const prompts = t.user.join("\n");
      for (const p of ["mac-1", "cloud-1"]) {
        const n = prompts.split(p).length - 1;
        if (n !== 1) throw new Error(`prompt ${p} appears ${n} times in the Mac's transcript: ${short(t.user)}`);
      }
      if (!/side=vm prompt=cloud-1/.test(t.agent) || !/side=mac prompt=mac-1/.test(t.agent)) throw new Error(`the replies are not both there: ${short(t.agent)}`);
      return { value: null, detail: "mac-1 and cloud-1 once each, with their side=mac and side=vm replies" };
    });
    await J.step("the next turn runs on the Mac", async () => {
      const mark = S.notes.length;
      await S.call("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "home-1" }] }, TURN_BUDGET_MS);
      const t = transcript(S.notes, id, mark);
      if (!/side=mac prompt=home-1/.test(t.agent)) throw new Error(`the reply was not the Mac's: ${short(t.agent)}`);
      const v = await view(id);
      if (v.holder !== device) throw new Error(`holder ${v.holder}`);
      return { value: null, detail: `answered side=mac; holder ${v.holder} epoch ${v.epoch}` };
    });
    return 0;
  } catch (e) {
    console.error(scrub(String((e as Error)?.stack ?? e), J.secrets));
    return 1;
  } finally {
    J.write(meta);
    const sk = sock as Socket | null;
    sk?.close();
    const d = daemon as ChildProcess | null;
    if (d && d.exitCode === null) d.kill("SIGTERM");
    await cleanup(api, owned, tag, (s) => J.record(s));
    J.write(meta);
  }
}

/** Removes the run's machine and revokes its install; each part records its own outcome. */
async function cleanup(api: Api, owned: { machine?: string; install?: string }, tag: string, record: (s: Step) => void) {
  if (owned.machine) {
    const t0 = Date.now();
    await api.deleteMachine(owned.machine, `${tag}-delete`).then(
      () => record({ step: "delete the run's machine", status: "pass", ms: Date.now() - t0, detail: owned.machine! }),
      (e) => record({ step: "delete the run's machine", status: "fail", ms: Date.now() - t0, detail: `${owned.machine}: ${String((e as Error)?.message ?? e)}` }));
  }
  if (owned.install) {
    const t0 = Date.now();
    await api.op("install.revoke", { install: owned.install }, `${tag}-install-revoke`).then(
      () => record({ step: "revoke the run's install", status: "pass", ms: Date.now() - t0, detail: owned.install! }),
      (e) => record({ step: "revoke the run's install", status: "skip", ms: Date.now() - t0, detail: String((e as Error)?.message ?? e) }));
  }
}

/** `--cleanup DIR`: the always() step's second try at what OUT/owned.json names. */
async function cleanupMode(apiOrigin: string, stack: "dev" | "prod", email: string, password: string, dir: string): Promise<number> {
  const file = path.join(dir, "owned.json");
  if (!existsSync(file)) { console.log("no owned.json: the run made nothing"); return 0; }
  const owned = JSON.parse(readFileSync(file, "utf8")) as { machine?: string; install?: string };
  if (!owned.machine && !owned.install) { console.log("the run made nothing"); return 0; }
  const api = new Api(apiOrigin);
  api.bearer = (await passwordSignIn(STACK[stack], email, password)).access;
  if (owned.machine) {
    const m = await api.read("cloud.machine.get", { machine: owned.machine }).catch(() => null);
    if (!m) owned.machine = undefined;
  }
  await cleanup(api, owned, `aj-cleanup-${Date.now().toString(36)}`, (s) => console.log(JSON.stringify(s)));
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
