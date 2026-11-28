#!/usr/bin/env bun
/**
 * AutoCloud storage sync, on production, every 15 min (hq synthetic-probes.yml autocloud-storage-sync-production;
 * its NOW probe is hq tools/fleet-reconcilers/probes.d/autocloud-storage-sync-production.json).
 *
 * Leo, 2026-11-27: "all we need obv is storage reliable sync SO MAKE IT RELIABLE AND FAST", and "you mark as
 * autocloud, it starts instantly and works like dropbox to sync your thing first with projectionfs then with the
 * full or compressed amount fast through git carry/freestyle tunnel", and "we need to be able to toggle a chat on and
 * off of autocloud".
 *
 * One scratch chat a run, on one 2 vCPU machine ("autocloud sync probe") that stays paused between runs:
 *
 *   setup             sign in (the production probe account), a cli install of this run's own for the laptop
 *                     daemon, the machine resumed (resume_ms) and made the owner's Auto machine, the stand-in harness
 *                     on it, the two clocks' offset (the shortest of three `date` round trips).
 *   laptop            this NIGHTLY's acpmux daemon in a fresh HOME with cloud.autoCloud on: the "Mac" is the daemon,
 *                     which is where sync lives; a Linux runner keeps the 15-min cadence cheap.
 *   scratch_chat      a checkout with a 24-file tree/ (committed) and an uncommitted file in it; session/new, Auto on.
 *   toggle_on         POST move {to: cloud}; toggle_on_ms is until the store's holder is vm:<machine>.
 *   tree_visible      a watcher on the machine, started before the toggle, hashes ~/Projects/auto/<id>/tree every
 *                     50 ms; tree_visible_ms is from the toggle to the hash matching the laptop's. Bound 3 s.
 *   mac_edit_to_vm    a file written on the laptop while the chat is on the machine; the watcher there sees it. Bound 2 s.
 *   vm_edit_to_mac    a file written on the machine; the runner polls for it every 10 ms. Bound 2 s.
 *   both_match        both trees hash the same.
 *   toggle_off        POST move {to: local, device}; until the holder is the laptop again.
 *   mac_has_vm_edits  the laptop's tree has the machine's edit and hashes as the machine's last did.
 *
 * Red on its first failing step, named in the row's `error` (autocloud-sync-verdict.ts); every later step still runs
 * when it can, so a red row still carries the timings it could take. Cross-clock times are good to the offset's round
 * trip (`rtt_ms` in the row): half of it either way.
 *
 *   bun scripts/cmux-next/autocloud-sync-probe.ts --acpmux PATH/acpmux --out DIR --result FILE.json
 *   bun scripts/cmux-next/autocloud-sync-probe.ts --mint-token STATE     (the daemon's `cmux --json auth token`)
 *
 * Credentials: CLOUD_PROBE_PRODUCTION_STACK_EMAIL and _PASSWORD. `--backend staging` with CMUX_DOGFOOD_STACK_* runs it
 * on staging.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { mintInstallToken, Socket, type InstallState } from "./auto-journey.ts";
import { STEPS, verdict, gated, clockOffset, crossClockMs, parseWatch, TREE_HASH_SH, type StepName, type StepResult } from "./autocloud-sync-verdict.ts";
import { Api, CHAT_START_SIZE, STACK, directExec, http, listAllMachines, passwordSignIn, resolveBackend, scrub, sleep, waitRunning, type Exec } from "./cloud-journey.ts";

export const PROBE = "autocloud-storage-sync-production";
export const MACHINE_NAME = "autocloud sync probe";
const INSTALL_PREFIX = "autocloud sync probe as-";
const HARNESS = "autocloud-sync-probe";
const MOVE_BUDGET_MS = 4 * 60_000;
/** How long a watcher on the machine waits for the tree, and for an edit: long enough that a slow sync still gets a
 * number, short enough for one exec (at most 300 s). */
const TREE_WATCH_S = 240;
const EDIT_WATCH_S = 30;
const TREE_FILES = 24;
const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; c="$(command -v "$c" || echo "$c")"; ';

type View = { id: string; holder: string; epoch: number; version: number; lastSeq: number; snapshot: number; standby: string[]; move?: unknown; leaseExpiresAt?: number };

const argValue = (name: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);
const msg = (e: unknown) => String((e as Error)?.message ?? e);
const agentScript = `#!/bin/sh\ncat >/dev/null\necho "AUTOCLOUD_SYNC_PROBE_REPLY"\n`;

/** A watcher run on the machine: every 50 ms until CHECK (a shell test) holds, or SECONDS pass. Prints `@@start NS`
 * when it begins, then `@@seen NS` (with ` first` when the first look already saw it) or `@@timeout LAST`. */
export function watcher(check: string, seconds: number, last = "echo"): string {
  return `${GUEST}echo "@@start $(date +%s%N)"; end=$(( $(date +%s) + ${seconds} )); n=0; ` +
    `while :; do n=$((n+1)); if ${check}; then t=$(date +%s%N); [ $n -eq 1 ] && echo "@@seen $t first" || echo "@@seen $t"; exit 0; fi; ` +
    `[ $(date +%s) -ge $end ] && { echo "@@timeout $(${last} 2>&1 | head -c 300 | tr '\\n' ' ')"; exit 0; }; sleep 0.05; done`;
}

async function main(): Promise<number> {
  const minting = argValue("--mint-token");
  if (minting) {
    const state = JSON.parse(readFileSync(minting, "utf8")) as InstallState;
    const t = await mintInstallToken(state);
    process.stdout.write(JSON.stringify({ access_token: t.access_token, expires_in: t.expires_in ?? 600, api_origin: state.api, team: state.team ?? null }));
    return 0;
  }
  const backend = resolveBackend(argValue("--backend") ?? "prod");
  const prod = backend.name !== "staging";
  const email = prod ? process.env.CLOUD_PROBE_PRODUCTION_STACK_EMAIL : process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = prod ? process.env.CLOUD_PROBE_PRODUCTION_STACK_PASSWORD : process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  const bin = path.resolve(argValue("--acpmux") ?? argValue("--cmux") ?? "");
  const prefix = argValue("--acpmux") ? [] : ["acp"];
  const out = path.resolve(argValue("--out") ?? "autocloud-sync-out");
  const resultFile = path.resolve(argValue("--result") ?? path.join(out, "result.json"));
  mkdirSync(out, { recursive: true });

  const results: StepResult[] = [];
  const secrets: string[] = [];
  const fields: Record<string, unknown> = { env: backend.name, api: backend.api };
  const put = (r: StepResult) => {
    r.detail = scrub(r.detail, secrets).slice(0, 400);
    results.push(r);
    console.log(JSON.stringify(r));
    return r;
  };
  /** A setup step: pass with its detail, or fail and stop the run. */
  const setup = async <T>(step: StepName, run: () => Promise<{ value: T; detail: string }>): Promise<T> => {
    const t0 = Date.now();
    try {
      const r = await run();
      put({ step, status: "pass", ms: Date.now() - t0, detail: r.detail });
      return r.value;
    } catch (e) {
      put({ step, status: "fail", ms: Date.now() - t0, detail: msg(e) });
      throw e;
    }
  };
  const writeRow = () => {
    const row = verdict(PROBE, results, fields);
    writeFileSync(resultFile, JSON.stringify(row, null, 2));
    return row;
  };

  const tag = `as-${Date.now().toString(36)}`;
  const api = new Api(backend.api);
  let daemon: ChildProcess | null = null;
  let sock: Socket | null = null;
  let machine = "";
  let install = "";
  let id = "";
  let priorAutoMachine: string | null = null;
  let autoTeam: unknown = null;
  const store = (method: string, route: string, body?: unknown, timeoutMs = 30_000) =>
    http(method, `${backend.api}/v1/auto-sessions${route}`, body, { authorization: `Bearer ${api.bearer}` }, timeoutMs, method === "GET");
  const view = async (sid: string): Promise<View> => {
    const r = await store("GET", `/${encodeURIComponent(sid)}`);
    if (r.status !== 200) throw new Error(`GET /v1/auto-sessions/${sid}: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
    return r.body.session as View;
  };
  const until = async (sid: string, what: string, want: (v: View) => boolean, budgetMs = MOVE_BUDGET_MS): Promise<View> => {
    const deadline = Date.now() + budgetMs;
    let v = await view(sid);
    while (!want(v)) {
      if (Date.now() > deadline) throw new Error(`${what}: not in ${budgetMs / 1000} s; holder ${v.holder} epoch ${v.epoch} snapshot ${v.snapshot} standby ${v.standby.join(",") || "none"} move ${short(v.move)}`);
      const r = await store("GET", `/${encodeURIComponent(sid)}/wait?after=${v.version}&timeoutMs=${Math.max(1000, Math.min(20_000, deadline - Date.now()))}`, undefined, 30_000);
      v = r.status === 200 ? (r.body.session as View) : (await sleep(1000), await view(sid));
    }
    return v;
  };

  try {
    if (!email || !password) throw new Error(prod ? "set CLOUD_PROBE_PRODUCTION_STACK_EMAIL and _PASSWORD" : "set CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD");
    if (!existsSync(bin)) throw new Error("--acpmux PATH: the NIGHTLY acpmux (or --cmux PATH: cmux-tui)");
    secrets.push(password);

    await setup("sign_in", async () => {
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      secrets.push(s.access, s.refresh);
      api.bearer = s.access;
      return { value: null, detail: `Stack ${backend.stack}` };
    });

    const installState = await setup("install", async () => {
      // This probe's installs from runs that died before revoking theirs; a failure here never fails the run.
      const listed = await api.read("install.list", {}).catch(() => null);
      let swept = 0;
      for (const i of Array.isArray(listed?.installs) ? listed.installs : []) {
        const m = typeof i?.name === "string" && i.name.startsWith(INSTALL_PREFIX) ? parseInt(i.name.slice(INSTALL_PREFIX.length), 36) : NaN;
        if (i?.revoked_at === null && Number.isFinite(m) && Date.now() - m > 3_600_000) await api.op("install.revoke", { install: i.id }, `${tag}-sweep-${i.id}`).then(() => swept++, () => {});
      }
      const user = await api.op("user.ensure", {}, `${tag}-ensure`);
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
      const pub = await crypto.subtle.exportKey("jwk", pair.publicKey);
      const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: pub.x, y: pub.y }, kind: "cli", name: `${INSTALL_PREFIX}${tag.slice(3)}`, device_name: "autocloud sync probe", platform: "linux" }, `${tag}-install`);
      install = inst.id;
      const state: InstallState = { api: backend.api, user: inst.user ?? user.id ?? user.user?.id, install: inst.id, jwk: await crypto.subtle.exportKey("jwk", pair.privateKey), ...(typeof inst.team === "string" ? { team: inst.team } : {}) };
      secrets.push((await mintInstallToken(state)).access_token);
      return { value: state, detail: `install ${inst.id}; ${swept} stale revoked` };
    });

    // The one machine, paused between runs: resumed here, created only when it is gone or failed.
    await setup("machine", async () => {
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
      const mine = rows.filter((r: any) => r?.name === MACHINE_NAME && !["deleted", "deleting"].includes(r.status));
      let row: any = mine.find((r: any) => r.status !== "failed") ?? null;
      for (const r of mine) if (r !== row) await api.deleteMachine(String(r.id ?? r.machine_id), `${tag}-drop-${r.id ?? r.machine_id}`).catch(() => {});
      const t0 = Date.now();
      let how: string;
      if (!row) {
        const v = await api.op("cloud.machine.create", { name: MACHINE_NAME, size: CHAT_START_SIZE }, `${tag}-create`);
        machine = String(v.machine?.id ?? v.machine);
        how = "created";
      } else {
        machine = String(row.id ?? row.machine_id);
        how = `was ${row.status}`;
        if (row.status === "paused" || row.status === "stopped") await api.op("cloud.machine.start", { machine }, `${tag}-start`);
      }
      const m = await waitRunning(api, machine, 300_000);
      fields.resume_ms = Date.now() - t0;
      fields.machine = machine;
      fields.machine_was = how;
      fields.guest_daemon = m?.image?.daemon_version ?? null;
      return { value: null, detail: `${machine} ${how}, running in ${fields.resume_ms} ms` };
    });

    await setup("auto_machine", async () => {
      let r = await store("GET", "/machine");
      if (r.status !== 200) throw new Error(`GET /machine: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      autoTeam = r.body.team;
      if (r.body.machine !== machine) {
        priorAutoMachine = typeof r.body.machine === "string" ? r.body.machine : null;
        const p = await store("PUT", "/machine", { team: r.body.team, machine });
        if (p.status !== 200) throw new Error(`PUT /machine: HTTP ${p.status} ${short(p.body?.error ?? p.body)}`);
        r = await store("GET", "/machine");
      }
      if (r.body.machine !== machine) throw new Error(`the store picks ${r.body.machine}, not ${machine}`);
      return { value: null, detail: `team ${r.body.team}${priorAutoMachine ? `; was ${priorAutoMachine}` : ""}` };
    });

    const exec: Exec = directExec(api, machine, { secrets });
    await setup("vm_harness", async () => {
      const script = "$HOME/.cmux/autocloud-sync-agent.sh";
      const cmd = `${GUEST}set -e; mkdir -p "$HOME/.config/cmux/harnesses" "$HOME/.cmux"; cat > "${script}" <<'AS_AGENT'\n${agentScript}AS_AGENT\nchmod 755 "${script}"; ` +
        `printf '%s\\n' 'schema = 1' 'id = "${HARNESS}"' 'protocol = "acp"' "command = \\"$c\\"" "args = [\\"acp\\", \\"cli-agent\\", \\"--\\", \\"${script.replace("$HOME", "'\"$HOME\"'")}\\"]" > "$HOME/.config/cmux/harnesses/${HARNESS}.toml"; ` +
        // Folders this probe's earlier chats left (their tree/ is this probe's): the disk stays the size of one run.
        `for d in "$HOME"/Projects/auto/*; do [ -f "$d/tree/.autocloud-sync-probe" ] && rm -rf "$d"; done; ` +
        `"$c" acp daemon reload >/dev/null 2>&1 || true; "$c" --version 2>/dev/null | head -1; echo "@@ok"`;
      const r = await exec(cmd, 120_000);
      if (!/@@ok/.test(r.stdout)) throw new Error(`exit ${r.code}: ${(r.stdout + r.stderr).slice(-300)}`);
      return { value: null, detail: `profile written; guest ${r.stdout.replace("@@ok", "").trim().slice(0, 100)}` };
    });

    await setup("clock", async () => {
      const samples: Array<{ before: number; vm: number; after: number }> = [];
      for (let i = 0; i < 3; i++) {
        const before = Date.now();
        const r = await exec("date +%s%N", 30_000);
        samples.push({ before, vm: Number(r.stdout.trim()) / 1e6, after: Date.now() });
      }
      const c = clockOffset(samples);
      fields.offset_ms = c.offsetMs;
      fields.rtt_ms = c.rttMs;
      return { value: null, detail: `machine minus runner ${c.offsetMs} ms, round trip ${c.rttMs} ms` };
    });

    // The laptop: the NIGHTLY daemon in this run's HOME.
    const home = path.join(out, "home");
    const work = path.join(home, "work");
    const tree = path.join(work, "tree");
    const socketPath = path.join(os.tmpdir(), `as-${process.pid}.sock`);
    const env: Record<string, string> = { ...(process.env as Record<string, string>) };
    for (const k of ["CLOUD_PROBE_PRODUCTION_STACK_EMAIL", "CLOUD_PROBE_PRODUCTION_STACK_PASSWORD", "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"]) delete env[k];
    await setup("mac_daemon", async () => {
      const harnesses = path.join(home, ".config", "cmux", "harnesses");
      mkdirSync(harnesses, { recursive: true });
      const settings = path.join(home, ".config", "cmux", "cmux-next.json");
      writeFileSync(settings, JSON.stringify({ cloud: { autoCloud: true } }, null, 2));
      const script = path.join(home, "agent.sh");
      writeFileSync(script, agentScript);
      chmodSync(script, 0o755);
      writeFileSync(path.join(harnesses, `${HARNESS}.toml`), `schema = 1\nid = "${HARNESS}"\nprotocol = "acp"\ncommand = ${JSON.stringify(bin)}\nargs = ${JSON.stringify([...prefix, "cli-agent", "--", script])}\n`);
      const state = path.join(out, "install-state.json");
      writeFileSync(state, JSON.stringify(installState), { mode: 0o600 });
      const stub = path.join(home, "bin", "cmux");
      mkdirSync(path.dirname(stub), { recursive: true });
      writeFileSync(stub, `#!/bin/sh\n[ "$1 $2 $3" = "--json auth token" ] || exit 2\nexec ${shq(process.execPath)} ${shq(fileURLToPath(import.meta.url))} --mint-token ${shq(state)}\n`);
      chmodSync(stub, 0o755);
      Object.assign(env, { HOME: home, CMUX_BIN: stub, CMUX_NEXT_CONFIG_FILE: settings, ACPMUX_SOCKET: socketPath, PATH: `${path.dirname(stub)}:${env.PATH ?? "/usr/bin:/bin"}` });
      delete env.ACPMUX_HOME;
      const log = path.join(out, "daemon.log");
      writeFileSync(log, "");
      const fd = openSync(log, "a");
      daemon = spawn(bin, [...prefix, "daemon", "run"], { env, stdio: ["ignore", fd, fd] });
      const deadline = Date.now() + 60_000;
      while (!existsSync(socketPath)) {
        if (daemon.exitCode !== null) throw new Error(`the daemon exited ${daemon.exitCode}: ${readFileSync(log, "utf8").slice(-300)}`);
        if (Date.now() > deadline) throw new Error(`no socket in 60 s: ${readFileSync(log, "utf8").slice(-300)}`);
        await sleep(100);
      }
      sock = await Socket.open(socketPath);
      await sock.call("initialize", { protocolVersion: 1, clientCapabilities: {} });
      const v = Bun.spawnSync([bin, "--version"]).stdout.toString().trim();
      fields.build = v.slice(0, 120);
      return { value: null, detail: `pid ${daemon.pid}; ${v.slice(0, 80)}` };
    });
    const S = sock as unknown as Socket;

    const git = (args: string[]) => {
      const r = Bun.spawnSync(["git", "-c", "user.name=AutoCloud Sync Probe", "-c", "user.email=autocloud-sync@example.com", "-c", "commit.gpgsign=false", ...args], { cwd: existsSync(work) ? work : home, env });
      if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString().slice(-300)}`);
      return r.stdout.toString().trim();
    };
    const hashHere = () => Bun.spawnSync(["sh", "-c", TREE_HASH_SH(shq(tree))]).stdout.toString().trim();
    let device = "";
    await setup("scratch_chat", async () => {
      git(["clone", "--quiet", "--depth", "1", "https://github.com/octocat/Hello-World.git", work]);
      mkdirSync(tree, { recursive: true });
      writeFileSync(path.join(tree, ".autocloud-sync-probe"), `${tag}\n`);
      for (let i = 0; i < TREE_FILES; i++) writeFileSync(path.join(tree, `f${String(i).padStart(2, "0")}.txt`), `${tag} file ${i}\n${"x".repeat(64 * (i + 1))}\n`);
      git(["add", "tree"]);
      git(["commit", "--quiet", "-m", `autocloud sync probe ${tag}`]);
      writeFileSync(path.join(tree, "uncommitted.txt"), `${tag} uncommitted on the laptop\n`);
      const created = await S.call("session/new", { cwd: work, mcpServers: [], _meta: { acpmux: { harness: HARNESS, policy: "approve-all" } } });
      id = String(created.sessionId);
      fields.chat = id;
      const set = await S.call("_acpmux/auto_session/set", { sessionId: id, auto: true });
      if (set?.autoSession?.auto !== true) throw new Error(`Auto did not go on: ${short(set)}`);
      const v = await until(id, "the store holds the chat as this laptop", (v) => v.holder.startsWith("device:") && v.snapshot >= 1);
      device = v.holder;
      return { value: null, detail: `${id} held by ${v.holder}, snapshot ${v.snapshot}` };
    });

    // The timed part: each step records its own result and the run goes on where it can.
    const offset = Number(fields.offset_ms);
    const folder = `"$HOME/Projects/auto/${id}"`;
    const localHash = hashHere();
    fields.tree_hash = localHash;
    const treeWatch = exec(watcher(`[ "$(${TREE_HASH_SH(`${folder}/tree`)})" = "${localHash}" ]`, TREE_WATCH_S, `ls ${folder}/tree`), (TREE_WATCH_S + 30) * 1000).catch((e) => ({ code: -1, stdout: `exec: ${msg(e)}`, stderr: "" }));
    // The watcher must be looking before the toggle, or its time would count the exec's own start.
    await sleep(Math.max(1500, 2 * Number(fields.rtt_ms)));
    const t0 = Date.now();
    let onMachine: View | null = null;
    try {
      const r = await store("POST", `/${encodeURIComponent(id)}/move`, { to: "cloud" });
      if (r.status !== 200) throw new Error(`POST move cloud: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
      onMachine = await until(id, "the chat moves to the machine", (v) => v.holder === `vm:${machine}`);
      put({ step: "toggle_on", status: "pass", ms: Date.now() - t0, detail: `holder ${onMachine.holder} epoch ${onMachine.epoch}` });
    } catch (e) {
      put({ step: "toggle_on", status: "fail", ms: null, detail: msg(e) });
    }
    const tw = parseWatch((await treeWatch).stdout);
    if (!onMachine) put({ step: "tree_visible", status: "fail", ms: null, detail: "skipped: toggle_on failed" });
    else if (tw.seenMs === null) put({ step: "tree_visible", status: "fail", ms: null, detail: `the laptop's tree (${TREE_FILES + 2} files) ${tw.detail}` });
    else put(gated("tree_visible", crossClockMs(t0, tw.seenMs, offset), `hash ${localHash.slice(0, 12)} on the machine`));

    if (onMachine) {
      // The laptop's edit to the machine.
      const token = `${tag}-mac-${Date.now()}`;
      const editWatch = exec(watcher(`grep -qF '${token}' ${folder}/tree/mac-edit.txt 2>/dev/null`, EDIT_WATCH_S, `ls -la ${folder}/tree/mac-edit.txt`), (EDIT_WATCH_S + 30) * 1000).catch((e) => ({ code: -1, stdout: `exec: ${msg(e)}`, stderr: "" }));
      await sleep(Math.max(1500, 2 * Number(fields.rtt_ms)));
      const sent = Date.now();
      writeFileSync(path.join(tree, "mac-edit.txt"), `${token}\n`);
      const ew = parseWatch((await editWatch).stdout);
      if (ew.seenMs === null) put({ step: "mac_edit_to_vm", status: "fail", ms: null, detail: `tree/mac-edit.txt ${ew.detail}` });
      else if (ew.startMs !== null && ew.startMs - offset > sent) put({ step: "mac_edit_to_vm", status: "fail", ms: null, detail: "the watcher started after the write: no time" });
      else put(gated("mac_edit_to_vm", crossClockMs(sent, ew.seenMs, offset), ew.firstPoll ? "seen on the first look (an upper bound)" : "seen by the machine's watcher"));

      // The machine's edit to the laptop.
      const vmToken = `${tag}-vm-${Date.now()}`;
      const local = path.join(tree, "vm-edit.txt");
      let stop = false;
      const seenHere = (async () => {
        const deadline = Date.now() + EDIT_WATCH_S * 1000 + 60_000;
        while (!stop && Date.now() < deadline) {
          if (existsSync(local) && readFileSync(local, "utf8").includes(vmToken)) return Date.now();
          await sleep(10);
        }
        return null;
      })();
      const w = await exec(`${GUEST}d=${folder}/tree; [ -d "$d" ] || { echo "@@missing"; exit 0; }; t=$(date +%s%N); printf '%s\\n' '${vmToken}' > "$d/vm-edit.txt"; echo "@@wrote $t"`, 60_000).catch((e) => ({ code: -1, stdout: `exec: ${msg(e)}`, stderr: "" }));
      const wrote = /@@wrote (\d+)/.exec(w.stdout);
      if (!wrote) {
        stop = true;
        put({ step: "vm_edit_to_mac", status: "fail", ms: null, detail: `the machine could not write tree/vm-edit.txt: ${w.stdout.slice(-200)}` });
      } else {
        const wroteRunner = Number(wrote[1]) / 1e6 - offset;
        const deadline = Date.now() + EDIT_WATCH_S * 1000;
        const at = await Promise.race([seenHere, (async () => { while (Date.now() < deadline) await sleep(200); return null; })()]);
        stop = true;
        if (at === null) put({ step: "vm_edit_to_mac", status: "fail", ms: null, detail: `tree/vm-edit.txt not on the laptop in ${EDIT_WATCH_S} s` });
        else put(gated("vm_edit_to_mac", Math.max(0, at - wroteRunner), "seen by the runner's 10 ms poll"));
      }

      // Both trees the same.
      const deadline = Date.now() + 5000;
      let vmHash = "";
      for (;;) {
        const r = await exec(`${GUEST}${TREE_HASH_SH(`${folder}/tree`)}`, 30_000).catch(() => ({ code: -1, stdout: "", stderr: "" }));
        vmHash = r.stdout.trim();
        if (vmHash && vmHash === hashHere()) { put({ step: "both_match", status: "pass", ms: null, detail: `hash ${vmHash.slice(0, 12)}` }); break; }
        if (Date.now() > deadline) { put({ step: "both_match", status: "fail", ms: null, detail: `machine ${vmHash.slice(0, 12) || "none"} vs laptop ${hashHere().slice(0, 12)}` }); break; }
        await sleep(250);
      }
      fields.vm_hash = vmHash;

      // Toggle off, and the laptop has the machine's work.
      const t1 = Date.now();
      let home2 = false;
      try {
        await until(id, "the laptop stands by", (v) => v.standby.includes(device));
        const r = await store("POST", `/${encodeURIComponent(id)}/move`, { to: "local", device });
        if (r.status !== 200) throw new Error(`POST move local: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
        const v = await until(id, "the chat comes home", (v) => v.holder === device && v.epoch > onMachine!.epoch);
        home2 = true;
        put({ step: "toggle_off", status: "pass", ms: Date.now() - t1, detail: `holder ${v.holder} epoch ${v.epoch}` });
      } catch (e) {
        put({ step: "toggle_off", status: "fail", ms: null, detail: msg(e) });
      }
      if (!home2) put({ step: "mac_has_vm_edits", status: "fail", ms: null, detail: "skipped: toggle_off failed" });
      else {
        const end = Date.now() + 60_000;
        for (;;) {
          const has = existsSync(local) && readFileSync(local, "utf8").includes(vmToken);
          const h = hashHere();
          if (has && h === vmHash) { put({ step: "mac_has_vm_edits", status: "pass", ms: null, detail: `vm-edit.txt here; hash ${h.slice(0, 12)} as the machine's` }); break; }
          if (Date.now() > end) { put({ step: "mac_has_vm_edits", status: "fail", ms: null, detail: `${has ? "vm-edit.txt here" : "no vm-edit.txt"}; laptop ${h.slice(0, 12)} vs machine ${vmHash.slice(0, 12)}` }); break; }
          await sleep(250);
        }
      }
    }
  } catch (e) {
    console.error(scrub(String((e as Error)?.stack ?? e), secrets));
    // An error no step caught: the first step without a result carries it, so the row still names where it stopped.
    if (!results.length || results.at(-1)!.status === "pass") {
      const at = STEPS.find((s) => !results.some((r) => r.step === s)) ?? "mac_has_vm_edits";
      put({ step: at, status: "fail", ms: null, detail: `driver: ${msg(e)}` });
    }
  } finally {
    writeRow();
    (sock as Socket | null)?.close();
    const d = daemon as ChildProcess | null;
    if (d && d.exitCode === null) d.kill("SIGTERM");
    // Cleanup never changes the verdict: its own outcome rides in the row.
    const cleanup: string[] = [];
    if (machine && id) await directExec(api, machine, { secrets })(`${GUEST}rm -rf "$HOME/Projects/auto/${id}"`, 60_000).catch((e) => cleanup.push(`rm folder: ${msg(e).slice(0, 120)}`));
    if (priorAutoMachine && autoTeam !== null) await store("PUT", "/machine", { team: autoTeam, machine: priorAutoMachine }).then((r) => { if (r.status !== 200) cleanup.push(`restore auto machine: HTTP ${r.status}`); }, (e) => cleanup.push(`restore auto machine: ${msg(e).slice(0, 120)}`));
    if (machine) {
      const t = Date.now();
      await api.op("cloud.machine.pause", { machine }, `${tag}-pause`).then(() => { fields.pause_ms = Date.now() - t; }, (e) => cleanup.push(`pause: ${msg(e).slice(0, 160)}`));
    }
    if (install) await api.op("install.revoke", { install }, `${tag}-revoke`).catch((e) => cleanup.push(`revoke: ${msg(e).slice(0, 120)}`));
    if (cleanup.length) fields.cleanup_failed = scrub(cleanup.join("; "), secrets);
    const row = writeRow();
    console.log(`${row.probe}: ${row.outcome}${row.error ? ` (${row.error})` : ""}`);
  }
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
