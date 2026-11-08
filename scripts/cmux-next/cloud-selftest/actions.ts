/**
 * The action catalogue: every user action and observable state of Cloud multiplayer, each mapped to the `cmux` verb
 * that does it (with --json) and, while that verb does not exist yet, to the backend route the verb calls. A step's
 * action runs through the first of: the CLI verb (if this cmux has it), the route (transport api, the verb recorded as
 * still to come), or nothing (PENDING on the lane that adds it). Harness actions (fixtures, the stub, local gateways)
 * are this runner's own.
 *
 * Verb names for lanes A-E follow CONTEXT.md UPDATE 4 and are matched to the lane branches as they land; a renamed
 * verb is a one-line change here, never in a scenario.
 */
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import type { Actor } from "./actors";
import { runCli, verbExists } from "./actors";
import type { ActionResult, Lane } from "./engine";
import { refreshSession, type FixtureTeam, type FixtureUser, type Fixtures, type Role } from "./fixtures";
import { MODEL_STUB_PY } from "../cloud-journey";
import { startGateway, type Gateway, type LocalStub, type StubFault } from "./faults";

export type Driver = "auto" | "cli" | "api";

export type RunCtx = {
  cmux: string | null;
  driver: Driver;
  api: string;
  run: string;
  dir: string;
  actors: Map<string, Actor>;
  vars: Record<string, unknown>;
  fixtures: Fixtures | null;
  users: Map<string, FixtureUser>;
  team: FixtureTeam | null;
  stub: LocalStub | null;
  gateways: Map<string, Gateway>;
  secrets: string[];
  /** Machines this run made, deleted at the end by their exact ids. */
  machines: Set<string>;
};

type Args = Record<string, any>;
export type ActionDef = {
  /** The lane that owns this action's CLI verb ("base": on feat-cmux-next today). */
  lane: Lane;
  summary: string;
  /** The verb's words, for `cmux WORDS --help` (does this cmux have it?). */
  verb?: string[];
  cli?: (a: Args, ctx: RunCtx, actor: Actor) => string[];
  /** The route the verb calls, used while the verb is missing (transport api). */
  api?: (a: Args, ctx: RunCtx, actor: Actor) => Promise<ActionResult>;
  /** This runner's own action (fixtures, stub, local gateway, an exec-built probe). */
  harness?: (a: Args, ctx: RunCtx, actor: Actor) => Promise<ActionResult>;
  timeoutMs?: number;
  /** The part of a successful answer steps match, the same for the verb and its route (e.g. `.gateway`). */
  answer?: (json: any) => any;
};

export type Resolution = { kind: "cli" | "api" | "harness"; argv?: string[] } | { kind: "pending"; lane: Lane; why: string } | { kind: "skip"; why: string };

/** Which way an action runs here (pure but for the verb probe). */
export function resolve(def: ActionDef, a: Args, ctx: RunCtx, actor: Actor, has: (words: string[]) => boolean = (w) => !!ctx.cmux && verbExists(ctx.cmux, w)): Resolution {
  if (def.harness) return { kind: "harness" };
  const verbHere = !!def.cli && !!def.verb && ctx.driver !== "api" && has(def.verb);
  if (verbHere) return { kind: "cli", argv: def.cli!(a, ctx, actor) };
  if (def.api && ctx.driver !== "cli") return { kind: "api" };
  if (def.cli && !ctx.cmux) return def.lane === "base" ? { kind: "skip", why: "no cmux binary (--cmux PATH)" } : { kind: "pending", lane: def.lane, why: `no cmux binary to look for \`cmux ${def.verb?.join(" ")}\`` };
  if (def.cli) return { kind: "pending", lane: def.lane, why: `\`cmux ${def.verb?.join(" ")}\` is not in this cmux yet` };
  return { kind: "skip", why: `no route for driver ${ctx.driver}` };
}

export async function runAction(def: ActionDef, a: Args, ctx: RunCtx, actor: Actor, how: Resolution): Promise<ActionResult> {
  const r = await (async () => {
    switch (how.kind) {
      case "harness":
        return def.harness!(a, ctx, actor);
      case "api":
        return def.api!(a, ctx, actor);
      case "cli":
        return runCli(ctx.cmux!, actor, how.argv!, def.timeoutMs ?? 180_000);
      default:
        throw new Error(`not runnable: ${how.kind}`);
    }
  })();
  return r.ok && def.answer ? { ...r, json: def.answer(r.json) } : r;
}

const ok = (json: any, transport: ActionResult["transport"] = "harness"): ActionResult => ({ ok: true, json, transport });
const fail = (code: string, message: string, json: any = null, transport: ActionResult["transport"] = "harness"): ActionResult => ({ ok: false, code, message, json, transport });
const key = (ctx: RunCtx, what: string) => `${ctx.run}-${what}-${randomBytes(4).toString("hex")}`;
/** The team gateway route, or the owner's personal one (lane B: platform-forward's personal route). */
const gatewayRoute = (a: Args) => (a.personal ? "/v1/cloud/inference-gateway/personal" : "/v1/cloud/inference-gateway");
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
/** The guest's own cmux-tui (cloud_start_chat.rs GUEST_PRELUDE, cloud-journey.ts GUEST). */
const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';

function user(ctx: RunCtx, name: string): FixtureUser {
  const u = ctx.users.get(name);
  if (!u) throw new Error(`no fixture user ${name}`);
  return u;
}
async function mutate(ctx: RunCtx, fn: (f: Fixtures, team: FixtureTeam) => Promise<unknown>): Promise<ActionResult> {
  if (!ctx.fixtures?.mutable || !ctx.team) return fail("fixtures.read_only", "this run's fixtures cannot change the team");
  try {
    return ok({ value: await fn(ctx.fixtures, ctx.team), synced: ctx.fixtures.synced });
  } catch (e) {
    const m = String((e as Error).message);
    return fail(/^[a-z_]+\.[a-z_.]+/.exec(m)?.[0] ?? "fixtures.failed", m);
  }
}

/** One command on a machine as the actor: `cmux machine access exec` when cmux is here, else the same two routes. */
export async function machineExec(ctx: RunCtx, actor: Actor, machine: string, command: string, timeoutMs = 60_000): Promise<ActionResult & { exec?: { code: number; stdout: string; stderr: string } }> {
  if (ctx.cmux && ctx.driver !== "api" && verbExists(ctx.cmux, ["machine", "access", "exec"])) {
    const argv = ["--json", "machine", "access", "exec", "--target", `machine:${machine}`, "--timeout-ms", String(Math.min(timeoutMs, 300_000)), ...(actor.team ? ["--team", actor.team] : []), "--", command];
    const r = await runCli(ctx.cmux, actor, argv, timeoutMs + 30_000);
    if (Number.isInteger(r.json?.exit_code)) return { ...r, ok: true, exec: { code: r.json.exit_code, stdout: String(r.json.stdout ?? ""), stderr: String(r.json.stderr ?? "") } };
    return r;
  }
  const s = await actor.request("POST", `/v1/cloud/machines/${machine}/client-session`, { ttl_seconds: 900 });
  if (!s.ok && s.code === "cloud.provider.unsupported") {
    const g = await actor.request("POST", `/v1/cloud/machines/${machine}/exec`, { command, timeoutMs: Math.min(timeoutMs, 300_000) }, { timeoutMs: timeoutMs + 15_000 });
    if (!g.ok) return g;
    const v = g.json?.value ?? g.json;
    return { ...g, exec: { code: Number(v.exitCode ?? v.exit_code ?? 1), stdout: String(v.stdout ?? ""), stderr: String(v.stderr ?? "") } };
  }
  if (!s.ok) return s;
  const v = s.json?.value ?? s.json;
  ctx.secrets.push(v.token);
  const res = await fetch(`${String(v.api_base_url).replace(/\/+$/, "")}/v5/vms/${v.vm_id}/exec-await`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-freestyle-identity-access-token": v.token },
    body: JSON.stringify({ command, linuxUser: v.linux_user, timeoutMs }),
    signal: AbortSignal.timeout(timeoutMs + 15_000),
  }).catch((e) => e as Error);
  if (res instanceof Error) return fail("network.unreachable", res.message, null, "api");
  const body: any = await res.json().catch(() => ({}));
  if (!res.ok) return fail(`exec.http_${res.status}`, "exec-await refused", body, "api");
  const code = body.statusCode ?? body.exitCode ?? body.code;
  return { ok: true, json: body, transport: "api", exec: { code: code == null ? 124 : Number(code), stdout: String(body.stdout ?? ""), stderr: String(body.stderr ?? "") } };
}

/** An exec whose program prints one `@@json {...}` line: that JSON, or the exec's failure. */
async function execJson(ctx: RunCtx, actor: Actor, machine: string, command: string, timeoutMs = 60_000): Promise<ActionResult> {
  const r = await machineExec(ctx, actor, machine, command, timeoutMs);
  if (!r.exec) return r;
  const line = r.exec.stdout.split("\n").reverse().find((l) => l.startsWith("@@json "));
  if (!line) return fail("exec.no_answer", `exit ${r.exec.code}: ${(r.exec.stdout + r.exec.stderr).slice(-400)}`, r.exec, r.transport);
  const json = JSON.parse(line.slice(7));
  if (json.ok === false) return fail(String(json.code ?? "exec.failed"), String(json.message ?? ""), json, r.transport);
  return { ok: true, json, transport: r.transport };
}

/** A turn error's stable code, from the harness's error text (gateway, provider, auth). */
export function turnErrorCode(text: string): string {
  // The daemon's own classification of the failed turn wins over words in the agent's message.
  const kind = /"errorKind"\s*:\s*"([a-z][a-z0-9_]*\.[a-z0-9_.]+)"/.exec(text);
  if (kind) return kind[1]!;
  const m = /\b(inference\.[a-z_]+)\b/.exec(text);
  if (m) return m[1]!;
  if (/rate[_ ]?limit|429/i.test(text)) return "provider.rate_limited";
  if (/overloaded|529/i.test(text)) return "provider.overloaded";
  if (/authentication|unauthori[sz]ed|401|invalid api key|not logged in/i.test(text)) return "provider.auth";
  return "turn.error";
}

/** The probe of `vm.credentials`: which login files exist and which provider variables hold more than a placeholder. */
export const CREDENTIAL_PROBE = String.raw`python3 - <<'PY'
import json, os, pathlib, subprocess
home = pathlib.Path(os.environ.get("HOME") or "/home/cmux")
files = [str(p) for p in [home/".claude/.credentials.json", home/".codex/auth.json", home/".config/cmux/claude-oauth-token",
         pathlib.Path("/etc/cmux/claude-oauth-token"), home/".config/gh/hosts.yml.cmux-login"] if p.exists() and p.stat().st_size > 0]
env = {}
try:
    env = dict(l.split("=", 1) for l in subprocess.run(["bash", "-lc", "env"], capture_output=True, text=True, timeout=10).stdout.splitlines() if "=" in l)
except Exception:
    pass
for f in ["/etc/cmux/model-plane.env", str(home/".config/cmux/model-plane.env")]:
    try:
        for l in open(f):
            if "=" in l and not l.startswith("#"):
                k, v = l.strip().split("=", 1); env.setdefault(k.replace("export ", ""), v.strip("'\""))
    except OSError:
        pass
names = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]
placeholder = lambda v: (not v) or v.startswith("cmux-") or "placeholder" in v.lower() or v in ("x", "dummy", "unused")
real = [n for n in names if not placeholder(env.get(n, ""))]
present = [n for n in names if env.get(n)]
# What the agents really get: the agent daemon's own environment (its children inherit it), names only.
daemon = {}
try:
    import re
    out = subprocess.run(["bash", "-lc", 'c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; "$c" acp --json daemon status'], capture_output=True, text=True, timeout=15).stdout
    m = re.search(r'"pid":\s*(\d+)', out)
    if m:
        daemon = dict(kv.split("=", 1) for kv in open(f"/proc/{m.group(1)}/environ", "rb").read().decode(errors="replace").split("\0") if "=" in kv)
except Exception:
    pass
print("@@json " + json.dumps({"ok": True, "files": files, "real_env": real, "auth_env": present,
      "daemon_seen": bool(daemon), "daemon_auth_env": [n for n in names if daemon.get(n)], "daemon_anthropic_base_url": daemon.get("ANTHROPIC_BASE_URL", ""),
      "anthropic_base_url": env.get("ANTHROPIC_BASE_URL", ""), "openai_base_url": env.get("OPENAI_BASE_URL", "")}))
PY`;

export const ACTIONS: Record<string, ActionDef> = {
  // ---- identity and team (base routes; CLI verbs from lane D) ----
  "account.ensure": {
    lane: "base",
    summary: "create or read the actor's cmux account (user.ensure)",
    api: async (_a, ctx, actor) => {
      const r = await actor.op("user.ensure", {}, key(ctx, `ensure-${actor.name}`), { team: null });
      if (r.ok && actor.identity) actor.identity.user = String(r.json?.id ?? r.json?.user?.id ?? actor.identity.user ?? "");
      return r;
    },
  },
  "team.list": {
    lane: "D",
    summary: "the teams this actor may act in, with its role (user.teams.list)",
    verb: ["cloud", "team", "list"],
    cli: () => ["--json", "cloud", "team", "list"],
    api: (_a, _ctx, actor) => actor.read("user.teams.list", {}, { team: null }),
  },
  "team.members": {
    lane: "D",
    summary: "the members of the actor's team (team.members.list)",
    verb: ["cloud", "team", "members"],
    cli: (a) => ["--json", "cloud", "team", "members", ...(a.team ? ["--team", a.team] : [])],
    api: (a, _ctx, actor) => actor.read("team.members.list", { limit: 100 }, { team: a.team ?? actor.team }),
  },
  "team.sessions": {
    lane: "D",
    summary: "the team's Cloud chats a member may open (owner, machine, session, live state)",
    verb: ["cloud", "team", "sessions"],
    cli: (a) => ["--json", "cloud", "team", "sessions", ...(a.team ? ["--team", a.team] : [])],
  },
  "auth.probe": {
    lane: "base",
    summary: "one read with a given credential (the actor's, an expired one, garbage, none)",
    harness: async (a, _ctx, actor) => {
      const token = a.token === "garbage" ? "not-a-token" : a.token === "expired" ? EXPIRED_JWT : a.token === "none" ? "" : actor.identity?.access_token;
      const r = await actor.read("user.teams.list", {}, { token: token ?? "", team: null });
      return { ...r, transport: "harness" };
    },
  },
  "auth.refresh": {
    lane: "base",
    summary: "refresh the actor's sign-in session with its refresh token (refused after a revoke)",
    harness: async (_a, ctx, actor) => {
      const rt = actor.identity?.refresh_token;
      if (!rt) return fail("fixtures.no_refresh_token", "this identity has no refresh token");
      const r = await refreshSession(rt);
      if (!r.ok) return fail("auth.refresh_refused", `HTTP ${r.status} ${r.code}`, r);
      ctx.secrets.push(r.access_token);
      actor.identity!.access_token = r.access_token;
      return ok({ refreshed: true });
    },
  },

  // ---- fixtures (harness) ----
  "fixtures.set_role": {
    lane: "base",
    summary: "give a fixture user a team role (adds the membership)",
    harness: (a, ctx) => mutate(ctx, (f, t) => f.setRole(t, user(ctx, a.user), a.role as Exclude<Role, "owner">)),
  },
  "fixtures.remove": {
    lane: "base",
    summary: "remove a fixture user from the team (access revoked live)",
    harness: (a, ctx) => mutate(ctx, (f, t) => f.remove(t, user(ctx, a.user))),
  },
  "fixtures.revoke_sessions": {
    lane: "base",
    summary: "end every sign-in session of a fixture user",
    harness: (a, ctx) => mutate(ctx, (f) => f.revokeSessions(user(ctx, a.user))),
  },

  // ---- machines (base routes; exec is the CLI's own headless verb) ----
  "machine.create": {
    lane: "base",
    summary: "create a small Cloud machine in the actor's team (cloud.machine.create)",
    api: async (a, ctx, actor) => {
      const r = await actor.op("cloud.machine.create", { name: `selftest ${ctx.run} ${a.name ?? actor.name}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, key(ctx, "create"));
      const id = r.json?.id ?? r.json?.machine?.id ?? r.json?.machine_id;
      if (r.ok && id) ctx.machines.add(String(id));
      return r.ok ? { ...r, json: { ...r.json, machine_id: id } } : r;
    },
  },
  "machine.get": {
    lane: "base",
    summary: "a machine's state (cloud.machine.get)",
    api: (a, _ctx, actor) => actor.read("cloud.machine.get", { machine: a.machine }),
  },
  "machine.list": {
    lane: "base",
    summary: "the machines the actor sees (cloud.machine.list)",
    api: (_a, _ctx, actor) => actor.read("cloud.machine.list", {}),
  },
  "machine.pause": { lane: "base", summary: "pause (the VM sleeps)", api: (a, ctx, actor) => actor.op("cloud.machine.pause", { machine: a.machine }, key(ctx, "pause")) },
  "machine.resume": { lane: "base", summary: "resume (the VM wakes)", api: (a, ctx, actor) => actor.op("cloud.machine.start", { machine: a.machine }, key(ctx, "start")) },
  "machine.delete": {
    lane: "base",
    summary: "delete by exact id",
    api: async (a, ctx, actor) => {
      const r = await actor.op("cloud.machine.delete", { machine: a.machine }, `${ctx.run}-delete-${a.machine}`);
      if (r.ok) ctx.machines.delete(String(a.machine));
      return r;
    },
  },
  "machine.exec": {
    lane: "base",
    summary: "one command on the machine (`cmux machine access exec`)",
    harness: async (a, ctx, actor) => {
      const r = await machineExec(ctx, actor, a.machine, a.command, a.timeout_ms ?? 60_000);
      if (!r.exec) return r;
      return { ok: r.exec.code === 0, code: r.exec.code === 0 ? undefined : `exec.exit_${r.exec.code}`, json: r.exec, transport: r.transport };
    },
  },
  "vm.credentials": {
    lane: "base",
    summary: "login-free VM: no login file and no real provider key on the machine, base URLs at the edge",
    harness: (a, ctx, actor) => execJson(ctx, actor, a.machine, CREDENTIAL_PROBE),
  },
  "vm.stub": {
    lane: "base",
    summary: "the model stub on the machine's loopback and Claude Code pointed at it (cloud-journey --model stub)",
    harness: async (a, ctx, actor) => {
      const stub = Buffer.from(readFileSync(MODEL_STUB_PY)).toString("base64");
      const script = Buffer.from(JSON.stringify(a.script ?? { version: 1, steps: [{ text: "Stub reply {{nonce}}." }] })).toString("base64");
      const nonce = String(a.nonce ?? ctx.run);
      const d = "/home/cmux/.cmux/selftest-stub";
      const cmd =
        `set -e; mkdir -p ${d}; echo ${stub} | base64 -d > ${d}/stub.py; echo ${script} | base64 -d > ${d}/script.json; ` +
        `rm -f ${d}/ready; (nohup python3 ${d}/stub.py --port 0 --script ${d}/script.json --nonce ${shq(nonce)} --log ${d}/log.jsonl --ready-file ${d}/ready >${d}/out 2>&1 &); ` +
        `for i in $(seq 50); do [ -s ${d}/ready ] && break; sleep 0.2; done; port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${d}/ready); ` +
        `python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\nc = json.loads(p.read_text()) if p.exists() else {}\ne = c.setdefault('env', {}); e['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]; e['ANTHROPIC_AUTH_TOKEN'] = 'selftest-stub-placeholder'\np.parent.mkdir(parents=True, exist_ok=True); p.write_text(json.dumps(c))\nprint('@@json ' + json.dumps({'ok': True, 'port': int(sys.argv[1])}))\nPY`;
      return execJson(ctx, actor, a.machine, cmd, 90_000);
    },
  },
  "vm.stub_fault": {
    lane: "base",
    summary: "queue faults on the machine's model stub (rate limit, auth, delay)",
    harness: (a, ctx, actor) =>
      execJson(ctx, actor, a.machine, `port=$(python3 -c 'import json; print(json.load(open("/home/cmux/.cmux/selftest-stub/ready"))["port"])'); r=$(curl -fsS -m 5 -H 'content-type: application/json' -d ${shq(JSON.stringify({ faults: a.faults }))} "http://127.0.0.1:$port/__stub/faults"); echo "@@json $r"`),
  },
  "vm.daemon_kill": {
    lane: "base",
    summary: "kill the machine's agent daemon (SIGKILL, as a crash or VM restart mid-turn); acpmux.service restarts it",
    harness: (a, ctx, actor) =>
      execJson(ctx, actor, a.machine, `${GUEST}p=$("$c" acp --json daemon status 2>/dev/null | grep -o '"pid": *[0-9]*' | head -1 | grep -o '[0-9]*$'); if [ -n "$p" ] && kill -KILL "$p"; then echo "@@json {\\"ok\\":true,\\"killed\\":$p}"; else echo '@@json {"ok":false,"code":"daemon.no_pid"}'; fi`),
  },

  // ---- chats on a machine (the owner's acpmux, through exec; members attach through lane C) ----
  "chat.start": {
    lane: "base",
    summary: "start an agent session on the machine (acp ensure)",
    harness: (a, ctx, actor) => execJson(ctx, actor, a.machine, `${GUEST}"$c" acp ensure ${shq(a.session)} -m ${shq(a.agent ?? "claude")} --json >/tmp/selftest-ensure.json 2>&1; e=$?; [ $e = 0 ] && echo '@@json {"ok":true}' || echo "@@json {\\"ok\\":false,\\"code\\":\\"chat.start_failed\\",\\"message\\":\\"exit $e\\"}"`, 120_000),
  },
  "chat.send": {
    lane: "base",
    summary: "send a prompt as the machine's owner (acp send --no-wait)",
    harness: (a, ctx, actor) => {
      const b64 = Buffer.from(String(a.text)).toString("base64");
      return execJson(ctx, actor, a.machine, `${GUEST}echo ${b64} | base64 -d | "$c" acp send --no-wait ${shq(a.session)} - >/tmp/selftest-send.out 2>&1; e=$?; [ $e = 0 ] && echo '@@json {"ok":true}' || echo "@@json {\\"ok\\":false,\\"code\\":\\"chat.send_failed\\",\\"message\\":\\"exit $e $(tail -c 200 /tmp/selftest-send.out | tr -d '\\"\\n')\\"}"`, 120_000);
    },
  },
  "chat.wait": {
    lane: "base",
    summary: "the turn's reply once it ends, or its error code (acp wait, acp last)",
    timeoutMs: 600_000,
    harness: async (a, ctx, actor) => {
      const t0 = Date.now();
      const budget = Number(a.timeout_ms ?? 300_000);
      while (Date.now() - t0 < budget) {
        const r = await machineExec(ctx, actor, a.machine, `${GUEST}"$c" acp wait ${shq(a.session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(a.session)} 2>&1 | tail -c 4000`, 45_000);
        if (!r.exec) return r;
        const wait = /@@wait (\d+)/.exec(r.exec.stdout)?.[1];
        const last = r.exec.stdout.replace(/@@wait \d+\n?/, "").trim();
        if (wait === "0" && last) return ok({ reply: last }, r.transport);
        if (wait === "2") return fail("chat.waits_on_permission", last.slice(-300), { reply: last }, r.transport);
        if (wait && wait !== "3" && wait !== "0") {
          const h = await machineExec(ctx, actor, a.machine, `${GUEST}"$c" acp tail ${shq(a.session)} 2>&1 | grep -E '"kind":"turn_error"' | tail -1`, 45_000);
          const why = h.exec?.stdout ?? last;
          return fail(turnErrorCode(why), why.slice(-400), { reply: last, error: why.slice(-400) }, r.transport);
        }
      }
      return fail("chat.timeout", `no reply within ${budget} ms`);
    },
  },
  "chat.history": {
    lane: "base",
    summary: "the session's turns as the owner sees them (acp --json history)",
    harness: (a, ctx, actor) =>
      execJson(ctx, actor, a.machine, `${GUEST}"$c" acp --json history ${shq(a.session)} --limit ${Number(a.limit ?? 50)} 2>/dev/null | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t[t.find("{"):]); turns=d.get("turns",[]); print("@@json "+json.dumps({"ok":True,"count":len(turns),"turns":[{"prompt":(x.get("prompt") or "")[:120],"author":x.get("author")} for x in turns]}))'`),
  },
  "chat.events": {
    lane: "base",
    summary: "the session's transcript events (acp tail): kinds, author stamps, queue and held state",
    harness: (a, ctx, actor) =>
      execJson(ctx, actor, a.machine, `${GUEST}"$c" acp tail ${shq(a.session)} 2>/dev/null | python3 -c 'import json,sys,collections; ev=[]\nfor l in sys.stdin:\n  try: ev.append(json.loads(l))\n  except ValueError: pass\nk=collections.Counter(e.get("kind","?") for e in ev); print("@@json "+json.dumps({"ok":True,"count":len(ev),"kinds":k,"authors":sorted({str((e.get("author") or {}).get("user") or (e.get("author") or {}).get("name") or "") for e in ev if e.get("author")})}))'`),
  },
  "chat.prompt_big": {
    lane: "base",
    summary: "send a large prompt (bytes) as a file on the machine, then send it",
    harness: async (a, ctx, actor) => {
      const marker = String(a.marker);
      const cmd = `${GUEST}python3 -c 'import sys; sys.stdout.write(sys.argv[1] + " " + "x" * int(sys.argv[2]))' ${shq(marker)} ${Number(a.bytes ?? 200_000)} > /tmp/selftest-big.txt; "$c" acp send --no-wait ${shq(a.session)} - < /tmp/selftest-big.txt >/dev/null 2>&1 && echo '@@json {"ok":true}' || echo '@@json {"ok":false,"code":"chat.send_failed"}'`;
      return execJson(ctx, actor, a.machine, cmd, 120_000);
    },
  },

  // ---- shared Cloud chats (lane C) ----
  "share.create": {
    lane: "C",
    summary: "share a Cloud chat (cloud:<team>/<vm>/<session>): a guest link or a member invite",
    verb: ["cloud", "share", "chat"],
    cli: (a) => ["--json", "cloud", "share", "chat", "--session", a.session, ...(a.role ? ["--role", a.role] : [])],
  },
  "share.list": { lane: "C", summary: "the chat's links and who joined", verb: ["cloud", "share", "list"], cli: (a) => ["--json", "cloud", "share", "list", "--session", a.session] },
  "share.revoke": { lane: "C", summary: "revoke a link (joined guests are dropped)", verb: ["cloud", "share", "revoke"], cli: (a) => ["--json", "cloud", "share", "revoke", a.share_id] },
  "share.join": { lane: "C", summary: "open a share link as this actor (guest)", verb: ["cloud", "share", "join"], cli: (a) => ["--json", "cloud", "share", "join", a.link] },
  "chat.attach": {
    lane: "C",
    summary: "attach to a shared Cloud chat (member or owner) and read its live state: presence, typing, queue",
    verb: ["cloud", "attach"],
    cli: (a) => ["--json", "cloud", "attach", "--session", a.session, ...(a.since ? ["--since", String(a.since)] : []), "--once"],
  },
  "chat.steer": {
    lane: "C",
    summary: "a prompt into the shared chat as this actor: members steer the running turn, guests are held",
    verb: ["cloud", "send"],
    cli: (a) => ["--json", "cloud", "send", "--session", a.session, "--text", a.text, ...(a.idempotency_key ? ["--idempotency-key", a.idempotency_key] : [])],
  },
  "chat.approve": { lane: "C", summary: "the owner lets a held guest prompt in", verb: ["cloud", "share", "approve"], cli: (a) => ["--json", "cloud", "share", "approve", "--session", a.session, "--prompt", a.prompt_id] },
  "chat.presence": { lane: "C", summary: "who is in the chat now (presence, typing)", verb: ["cloud", "presence"], cli: (a) => ["--json", "cloud", "presence", "--session", a.session] },
  "chat.remote_events": {
    lane: "C",
    summary: "the shared chat's events from a cursor, as an attached member sees them (no loss, no duplicate)",
    verb: ["cloud", "events"],
    cli: (a) => ["--json", "cloud", "events", "--session", a.session, ...(a.since ? ["--since", String(a.since)] : [])],
  },

  // ---- team chats: follow, reassign, transfer, links (lane D) ----
  "chat.follow": { lane: "D", summary: "follow a teammate's Cloud chat", verb: ["cloud", "follow"], cli: (a) => ["--json", "cloud", "follow", "--session", a.session, "--once"] },
  "chat.reassign": { lane: "D", summary: "reassign a Cloud chat to another member", verb: ["cloud", "reassign"], cli: (a) => ["--json", "cloud", "reassign", "--session", a.session, "--to", a.to] },
  "chat.transfer_local": { lane: "D", summary: "bring a Cloud chat back to this Mac", verb: ["cloud", "transfer-local"], cli: (a) => ["--json", "cloud", "transfer-local", "--session", a.session] },
  "link.session": {
    lane: "D",
    summary: "the cmux://cloud/session/<team>/<vm>/<session> link of a chat, and what it opens",
    verb: ["cloud", "link"],
    cli: (a) => ["--json", "cloud", "link", ...(a.url ? ["--parse", a.url] : ["--session", a.session])],
  },

  // ---- gateway (lane B) ----
  "gateway.status": {
    lane: "B",
    summary: "the team's (or owner's) gateway mode and whether one is online",
    verb: ["inference", "gateway", "status"],
    cli: (a) => ["--json", "inference", "gateway", "status", ...(a.personal ? ["--personal"] : [])],
    // Both answer {ok, [scope,] gateway: {mode, machine, online, kind, connected_at}}; steps match the gateway itself.
    api: (a, _ctx, actor) => actor.request("GET", gatewayRoute(a)),
    answer: (j) => j?.gateway ?? j,
  },
  "gateway.mode": {
    lane: "B",
    summary: "set the team's (or with personal, the owner's own) gateway mode (gateway | off)",
    verb: ["inference", "gateway", "mode"],
    cli: (a) => ["--json", "inference", "gateway", "mode", String(a.mode), ...(a.personal ? ["--personal"] : []), ...(a.machine ? ["--gateway-machine", String(a.machine)] : [])],
    api: (a, _ctx, actor) => actor.request("PUT", gatewayRoute(a), { mode: a.mode, machine: a.machine ?? null }),
    answer: (j) => j?.gateway ?? j,
  },
  "gateway.route": {
    lane: "B",
    summary: "which route a machine's next model call takes (team_key | owner_key | owner_gateway | team_gateway), asked from the machine",
    verb: ["inference", "route"],
    cli: (a) => ["--json", "inference", "route", "--machine", String(a.machine), "--agent", String(a.agent ?? "claude")],
  },
  "gateway.start": {
    lane: "base",
    summary: "start `cmux inference gateway` on this computer as the actor, in front of the local stub",
    harness: async (a, ctx, actor) => {
      if (!ctx.cmux) return fail("cli.missing", "no cmux binary (--cmux PATH)");
      if (!ctx.stub && !a.upstream) return fail("stub.missing", "no local model stub");
      const g = startGateway(ctx.cmux, actor.env(), { id: String(a.id ?? "g1"), api: ctx.api, upstream: String(a.upstream ?? ctx.stub!.url), token: actor.identity!.access_token, team: actor.team, personal: !!a.personal, dir: ctx.dir });
      ctx.gateways.set(g.id, g);
      return ok({ id: g.id, pid: g.pid });
    },
  },
  "gateway.stop": {
    lane: "base",
    summary: "stop one gateway this run started (the owner's Mac asleep, a gateway gone)",
    harness: async (a, ctx) => {
      const g = ctx.gateways.get(String(a.id ?? "g1"));
      // Idempotent: a cleanup may stop one that a step already stopped.
      if (!g) return ok({ id: String(a.id ?? "g1"), stopped: false });
      await g.stop();
      ctx.gateways.delete(g.id);
      return ok({ id: g.id, stopped: true });
    },
  },
  "stub.fault": {
    lane: "base",
    summary: "queue faults on the local model stub behind the gateway (rate limit, auth, overload, delay)",
    harness: async (a, ctx) => (ctx.stub ? ok({ pending: await ctx.stub.setFaults(a.faults as StubFault[]) }) : fail("stub.missing", "no local model stub")),
  },
  "stub.calls": {
    lane: "base",
    summary: "the model calls the local stub saw (count, credential hashes, faults)",
    harness: async (_a, ctx) => {
      if (!ctx.stub) return fail("stub.missing", "no local model stub");
      const rows = (await ctx.stub.rows()).filter((r) => r.method === "POST" && !r.side);
      return ok({ count: rows.length, faulted: rows.filter((r) => r.fault).length, creds: [...new Set(rows.map((r) => r.cred_sha256))] });
    },
  },

  // ---- team shared keys (lane E) ----
  "team_keys.status": { lane: "E", summary: "which agents have a team shared key (never the secret)", verb: ["cloud", "team-keys", "status"], cli: () => ["--json", "cloud", "team-keys", "status"] },
  "team_keys.set": {
    lane: "E",
    summary: "an admin sets the team's shared key for an agent",
    verb: ["cloud", "team-keys", "set"],
    cli: (a) => ["--json", "cloud", "team-keys", "set", "--agent", a.agent, "--kind", a.kind ?? "api_key", "--secret-file", a.secret_file],
  },
  "team_keys.clear": { lane: "E", summary: "an admin clears it", verb: ["cloud", "team-keys", "clear"], cli: (a) => ["--json", "cloud", "team-keys", "clear", "--agent", a.agent] },

  // ---- VM auth (lane A) ----
  "vm.auth_status": {
    lane: "A",
    summary: "how the machine's agents reach models (edge, placeholder keys) as the app shows it",
    verb: ["cloud", "machine-auth"],
    cli: (a) => ["--json", "cloud", "machine-auth", "--target", `machine:${a.machine}`],
  },
};

/** A Stack-shaped JWT that expired in 2020 (unsigned garbage signature): the API must answer auth.unauthenticated. */
export const EXPIRED_JWT = `${Buffer.from(JSON.stringify({ alg: "ES256", kid: "selftest", typ: "JWT" })).toString("base64url")}.${Buffer.from(JSON.stringify({ sub: "selftest", exp: 1577836800, iat: 1577833200, iss: "https://api.stack-auth.com/api/v1/projects/454ecd03-1db2-4050-845e-4ce5b0cd9895" })).toString("base64url")}.c2VsZnRlc3Q`;
