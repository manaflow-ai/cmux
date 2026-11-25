#!/usr/bin/env bun
/**
 * One Chief turn on a cmux Cloud machine of staging, read back (Cloud Chiefs, workstream 12).
 *
 *   bun scripts/cmux-next/cloud-chief-turn-proof.ts --bundle chief.tgz --out DIR
 *
 * What OPTCHAT_CHIEF_TURN_CREDENTIALS=1 (optchat-chief src/turn_credential.rs) is for: a Chief host whose own environment
 * has a Claude credential, on a machine whose shared model route RESOLVES. acpmux fills the route from
 * /etc/cmux/model-plane.env into every agent it starts, for each name the agent lacks (cloud_model_plane.rs `missing`,
 * login_env.rs `apply_tokio_for`), so an inherited CLAUDE_CODE_OAUTH_TOKEN still gets ANTHROPIC_BASE_URL (the edge) and
 * the placeholder ANTHROPIC_API_KEY, which Claude Code uses before the token: the turn goes to the edge and fails when the
 * edge does not serve the machine. With the opt-in the host sends its credential as `_meta.acpmux.credentials`, and
 * acpmux unsets the route for that agent (agent_credentials.rs `apply`, agent/command.rs route unset). Where the route
 * does NOT resolve (staging and production today, cmux-platform#1839), acpmux drops it (`machine_plane`) and an
 * inherited credential reaches Claude with or without the opt-in (run 45566468249: both runs answered "OK").
 * tests/turn_model_route.rs pins which sessions get the credential.
 *
 * Staging has no resolving route, so this script makes one on its own test machine: it maps the hosts the image's
 * /etc/cmux/model-plane.env names to 127.0.0.1 in that machine's /etc/hosts (sudo -n), so the route resolves and
 * refuses, as an edge that does not serve the machine does.
 *
 * It signs in as the staging agent test account (CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD), creates a machine named
 * `cmux-test-chief-<tag>`, copies the bundle (an optchat-chief built from this checkout and its measure/ driver) to it
 * through fs/write, and runs measure/chief_driver.py there twice, one turn each ("Reply with exactly one word: OK").
 * Both runs use the machine's own cmux-tui and an acpmux daemon of the machine's acpmux binary that the host starts (the
 * machine's running daemon is not dumpable, so optchat-chief's peer check, acpmux_peer.rs, refuses a host that did not
 * start it: run 45011412959), and both hosts have the Claude credential in their environment (a 0600 file the driver
 * deletes). The machine has no Claude sign-in.
 *   control: without the opt-in; expected: no model reply (the turn goes to the refusing route).
 *   proof:   with OPTCHAT_CHIEF_TURN_CREDENTIALS=1; expected: a model reply.
 * Then it deletes the machine (also on a signal), and machines of an earlier run of this script over an hour old,
 * by their exact name. proof.json and summary.md go to --out. Secrets are scrubbed from every line printed.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { Api, Journey, STACK, directExec, listAllMachines, passwordSignIn, resolveBackend, scrub } from "./cloud-journey.ts";

const argValue = (flag: string, argv: string[]) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : undefined; };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
/** Under FILE_MAX_BYTES (cmux-platform MachineGuest.ts, 8 MiB) once base64 is decoded. */
const PIECE = 6 * 1024 * 1024;
const NAME_PREFIX = "cmux-test-chief-";
const HOME = "/home/cmux";
/** How long a machine create keeps resending a timed-out request under its key. */
const CREATE_BUDGET_MS = 240_000;
const DIR = `${HOME}/.cmux-chief-proof`;
/** The machine's cmux-tui, as the journey finds it. */
const FIND_CMUX = 'c=$(command -v cmux-tui || true); [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
export const NOT_SIGNED_IN = /not signed in|not logged in/i;
/** The model's own answer to "Reply with exactly one word: OK" (run 45014138990's "Can't answer “Reply with exactly one
 * word: OK” yet" quoted the prompt and must not pass). */
export const MODEL_OK = /^\W*ok\W*$/i;

export type RunResult = { label: string; exit: string; replies: string[]; timeout: boolean | null; why: string };

/** A run's verdict: the proof wants a model reply ("OK"), the control none (its turn went to the refusing route). */
export function judge(label: "control" | "proof", r: RunResult): boolean {
  const text = r.replies.join("\n");
  if (label === "control") return !r.replies.some((x) => MODEL_OK.test(x.trim()));
  return r.replies.some((x) => MODEL_OK.test(x.trim())) && !NOT_SIGNED_IN.test(text);
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging");
  if (backend.name === "prod" || backend.stack === "prod") throw new Error("staging only");
  const bundle = argValue("--bundle", argv);
  if (!bundle) throw new Error("--bundle FILE (a .tgz with bin/optchat-chief and measure/)");
  const outDir = path.resolve(argValue("--out", argv) ?? "cloud-chief-turn-proof");
  mkdirSync(outDir, { recursive: true });
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  // An Anthropic API key when the repository has one (run 45016176371: the shared Claude Code token was at its weekly
  // limit), else the Claude Code token. One of them only: the host takes the first of turn_credential.rs NAMES.
  const apiKey = (process.env.ANTHROPIC_API_KEY ?? "").trim();
  const credName = apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN";
  const token = apiKey || (process.env.CLAUDE_CODE_OAUTH_TOKEN ?? "").trim();
  if (!email || !password) throw new Error("no agent test account: CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
  if (!token) throw new Error("no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN");
  // `<base36 start time>-<run>`: the sweep below reads the time back.
  const runId = (argValue("--run", argv) ?? "local").replace(/[^a-z0-9]/gi, "").toLowerCase();
  const tag = `${Date.now().toString(36)}-${runId}`;
  const J = new Journey(backend, outDir, { tag });
  J.secrets.push(password, token);
  const say = (line: string) => console.log(scrub(line, J.secrets));
  const report: Record<string, unknown> = { backend: backend.name, tag, credential: credName, runs: [] as RunResult[] };
  const api = new Api(backend.api);
  let machine: string | null = null;
  const remove = async (id: string) => {
    try { await api.deleteMachine(id, `${tag}-delete-${id}`); say(`deleted ${id}`); }
    catch (e) { say(`delete ${id}: ${(e as Error).message}`); }
  };
  const onSignal = async () => { if (machine) await remove(machine); process.exit(143); };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  const write = (verdict: string) => {
    writeFileSync(path.join(outDir, "proof.json"), `${scrub(JSON.stringify({ ...report, verdict }, null, 2), J.secrets)}\n`);
    const rows = (report.runs as RunResult[]).map((r) => `| ${r.label} | ${r.exit} | ${r.timeout} | ${r.replies.map((x) => x.replace(/\s+/g, " ").slice(0, 300)).join(" / ") || "(none)"} | ${r.why.slice(0, 200)} |`);
    writeFileSync(path.join(outDir, "summary.md"), scrub(`## Chief turn on a Cloud machine (${backend.name})\n\nmachine \`${report.machine ?? "?"}\` (\`${NAME_PREFIX}${tag}\`), deleted: ${report.deleted ?? "?"}\n\n**${verdict}**\n\n| run | driver exit | timed out | Chief reply | note |\n|---|---|---|---|---|\n${rows.join("\n")}\n`, J.secrets));
  };
  let verdict = "FAIL: did not finish";
  try {
    api.bearer = await J.step("sign in (agent test account)", async () => {
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      return { value: s.access, detail: "password" };
    });
    await J.step("user.ensure", async () => ({ value: await api.op("user.ensure", {}, `${tag}-ensure`), detail: "ok" }));
    // Earlier runs cut off before their delete: their exact name, over an hour old.
    const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
    for (const m of rows) {
      const t = new RegExp(`^${NAME_PREFIX}([0-9a-z]+)-[0-9a-z]+$`).exec(String(m?.name ?? ""));
      const at = t ? parseInt(t[1], 36) : NaN;
      if (Number.isFinite(at) && at > Date.UTC(2026, 0, 1) && Date.now() - at > 3_600_000 && m.status !== "deleted" && m.status !== "deleting") await remove(String(m.id));
    }
    machine = await J.step("create machine", async () => {
      // A create the API holds past op()'s 60 s request bound is sent again under the same key (it cannot make a
      // second machine), until CREATE_BUDGET_MS: runs 45563369047 and 45561125243 timed out at 60 s on staging.
      const t0 = Date.now();
      let a: any;
      for (let tries = 1; ; tries++) {
        try {
          a = await api.op("cloud.machine.create", { name: `${NAME_PREFIX}${tag}`, size: { cpu: 4, memory_mb: 8192, disk_mb: 16384 } }, `${tag}-create`);
          if (tries > 1) say(`create answered on try ${tries} after ${Math.round((Date.now() - t0) / 1000)} s`);
          break;
        } catch (e) {
          const timedOut = (e as Error)?.name === "TimeoutError" || /operation timed out/i.test(String((e as Error)?.message));
          if (!timedOut || Date.now() - t0 > CREATE_BUDGET_MS) throw new Error(`${(e as Error).message} (try ${tries}, ${Math.round((Date.now() - t0) / 1000)} s)`);
          say(`create try ${tries} timed out at ${Math.round((Date.now() - t0) / 1000)} s; sending it again under the same key`);
        }
      }
      const id = typeof a?.machine === "string" ? a.machine : a?.machine?.id ?? a?.machine_id ?? a?.id;
      if (typeof id !== "string") throw new Error(`create answered no machine id`);
      return { value: id, detail: id };
    });
    report.machine = machine;
    await J.step("machine running", async () => {
      const t0 = Date.now();
      for (;;) {
        const m = await api.read("cloud.machine.get", { machine }).catch(() => null);
        if (m?.status === "running" && m?.host) return { value: null, detail: `${Math.round((Date.now() - t0) / 1000)} s` };
        if (m?.status === "failed") throw new Error("machine failed");
        if (Date.now() - t0 > 300_000) throw new Error(`still ${m?.status} after 300 s`);
        await sleep(2000);
      }
    });
    const exec = directExec(api, machine, J);
    const run = async (command: string, timeoutMs = 120_000) => {
      const r = await exec(`export HOME=${HOME}; cd "$HOME"; ${command}`, timeoutMs);
      return { ...r, stdout: scrub(r.stdout, J.secrets), stderr: scrub(r.stderr, J.secrets) };
    };
    const writeFile = async (file: string, data: Buffer, mode: number) => {
      const w = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: file, dataBase64: data.toString("base64"), mode }, 120_000);
      if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${file}: HTTP ${w.status} ${String(w.body?.error?.code ?? "")}`);
    };
    await J.step("copy optchat-chief and its driver", async () => {
      const data = readFileSync(bundle);
      const n = Math.ceil(data.length / PIECE);
      await run(`rm -rf ${DIR} && mkdir -p ${DIR}/parts`);
      for (let i = 0; i < n; i++) await writeFile(`${DIR}/parts/${String(i).padStart(3, "0")}`, data.subarray(i * PIECE, (i + 1) * PIECE), 0o644);
      const r = await run(`cd ${DIR} && cat parts/* | tar xz && rm -rf parts && ./bin/optchat-chief --version 2>&1 | head -1`);
      if (r.code !== 0) throw new Error(`unpack: exit ${r.code} ${r.stderr.slice(-400)}`);
      return { value: null, detail: `${data.length} bytes in ${n} pieces; ${r.stdout.trim().slice(0, 120)}` };
    });
    const facts = await J.step("machine facts", async () => {
      const r = await run(`${FIND_CMUX}echo "cmux-tui=$c"; "$c" --version 2>&1 | head -1; ` +
        `for s in "$ACPMUX_SOCKET" "$HOME/.cmux/acpmux/acpmux.sock" "$HOME/.acpmux/acpmux.sock"; do [ -n "$s" ] && [ -S "$s" ] && { echo "acpmux_socket=$s"; break; }; done; ` +
        `echo "acpmux=$(command -v acpmux || true)"; echo "claude=$(command -v claude || ls $HOME/.local/bin/claude 2>/dev/null || true)"; ` +
        `ls $HOME/.claude/.credentials.json 2>/dev/null && echo has_claude_login || echo no_claude_login; ` +
        `getent hosts coderouter.cmux.internal >/dev/null && echo coderouter_resolves || echo coderouter_unresolved; uname -m; ldd --version 2>&1 | head -1; echo "cmux_bin=$(ls $HOME/.cmux/bin 2>/dev/null | tr '\\n' ' ')"`);
      const kv = Object.fromEntries(r.stdout.split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
      if (!kv["cmux-tui"]) throw new Error(`no cmux-tui on the machine: ${r.stdout.slice(0, 400)}`);
      if (!kv.acpmux_socket) throw new Error(`no acpmux socket on the machine: ${r.stdout.slice(0, 400)}`);
      report.facts = r.stdout.trim();
      return { value: kv, detail: r.stdout.trim().replace(/\n/g, "; ").slice(0, 600) };
    });
    // The staging image has no Claude Code (run 45014138990: "acpmux has no harness named claude"). The image is
    // another lane's; this test machine only gets the official installer's copy in ~/.local/bin.
    if (!facts.claude) await J.step("install Claude Code on this test machine", async () => {
      const r = await run(`curl -fsSL https://claude.ai/install.sh | bash >/tmp/claude-install.log 2>&1; tail -3 /tmp/claude-install.log; "$HOME/.local/bin/claude" --version`, 280_000);
      if (r.code !== 0) throw new Error(`install: exit ${r.code} ${(r.stdout + r.stderr).slice(-400)}`);
      return { value: null, detail: r.stdout.trim().split("\n").pop() ?? "" };
    });
    // The state the opt-in is for: the machine's model route resolves (header). Every host the image's route names goes
    // to 127.0.0.1 in this test machine's /etc/hosts; nothing listens there on 443, so the route refuses.
    await J.step("make the machine's model route resolve (and refuse)", async () => {
      const r = await run(`f=/etc/cmux/model-plane.env; [ -r "$f" ] || { echo "no $f"; exit 3; }; ` +
        `hosts=$(sed -n "s/^export \\(ANTHROPIC_BASE_URL\\|OPENAI_BASE_URL\\|CMUX_CODEROUTER_URL\\)='https:\\/\\/\\([^/:']*\\).*/\\2/p" "$f" | sort -u | tr '\\n' ' '); ` +
        `[ -n "$hosts" ] || { echo "no base URL host in $f"; exit 3; }; ` +
        `for h in $hosts; do getent hosts "$h" >/dev/null || echo "127.0.0.1 $h" | sudo -n tee -a /etc/hosts >/dev/null || exit 4; done; ` +
        `for h in $hosts; do getent hosts "$h" >/dev/null || { echo "$h still does not resolve"; exit 5; }; echo "resolves=$h"; done`);
      if (r.code !== 0) throw new Error(`route: exit ${r.code} ${(r.stdout + r.stderr).trim().slice(-400)}`);
      report.route = r.stdout.trim();
      return { value: null, detail: r.stdout.trim().replace(/\n/g, "; ") };
    });
    // The driver's bins: this checkout's optchat-chief, the machine's cmux-tui, and acpmux as the machine runs it.
    const acpmux = facts.acpmux ? `ln -sf ${shq(facts.acpmux)} ${DIR}/bin/acpmux` : `printf '#!/bin/sh\\nexec %s acp "$@"\\n' ${shq(facts["cmux-tui"])} > ${DIR}/bin/acpmux && chmod +x ${DIR}/bin/acpmux`;
    await run(`ln -sf ${shq(facts["cmux-tui"])} ${DIR}/bin/cmux-tui && ${acpmux}`);
    const oneRun = async (label: "control" | "proof"): Promise<RunResult> => {
      // fs/write's file is not the exec user's (run 45010085517: a 0600 one was unreadable), so it is 0644 in a 0700
      // directory of the exec user's, as the journey's login copy (cloud-journey.ts); the driver deletes it.
      const login = `${DIR}/private/${label}.login.env`;
      await run(`mkdir -p ${DIR}/private && chmod 700 ${DIR}/private`);
      // The driver's --login-env reads only a Claude Code token; the file is also sourced into the driver's environment
      // (the host inherits it), so an API key reaches the host without ever being on a command line.
      await writeFile(login, Buffer.from(`${credName}=${token}\n`), 0o644);
      const optIn = label === "proof" ? "--env OPTCHAT_CHIEF_TURN_CREDENTIALS=1" : "";
      const out = `${DIR}/${label}`;
      // In the foreground, inside one exec: a machine with no exec in flight stops on its own (run 45007797355
      // stopped 3 min into a background driver polled every 10 s: 409 vm_not_running; cloud-journey.ts 43983037186).
      let done = false;
      try {
        const d = await run(`export PATH="$HOME/.local/bin:$PATH"; set -a; . ${login}; set +a; timeout -k 5 265 python3 ${DIR}/measure/chief_driver.py --scenario smoke --only s03 --out ${out} --bins ${DIR}/bin ` +
          `--login-env ${login} --delete-login-env --turn-timeout 200 --max-settle 0 ${optIn} ` +
          `> ${DIR}/${label}.log 2>&1 < /dev/null; echo "driver_exit=$?"`, 290_000);
        done = /driver_exit=0\b/.test(d.stdout);
        say(`${label}: ${d.stdout.trim().split("\n").pop()}`);
      } catch (e) {
        report[`${label}_exec_error`] = (e as Error).message;
        report[`${label}_machine_row`] = await api.read("cloud.machine.get", { machine }).then((m: any) => ({ status: m?.status, pause_reason: m?.pause_reason ?? m?.pauseReason, paused_by: m?.paused_by ?? m?.pausedBy }), () => "read failed");
        say(`${label}: exec ${(e as Error).message}; machine ${JSON.stringify(report[`${label}_machine_row`])}`);
        throw e;
      }
      const r = await run(`tail -c 3000 ${DIR}/${label}.log; echo; echo ==RAW==; cat ${out}/raw.json 2>/dev/null || echo '{}'; echo; echo ==CONV==; ` +
        `python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([" ".join(p.get("text","") for p in m.get("parts",[]) if p.get("type")=="text")[:1500] for m in d.get("messages",[]) if m.get("author")=="agent_mux"]))' ${out}/conversation.json 2>/dev/null; ` +
        `echo ==HOST==; grep -iE "credential|not signed|not logged|turn.end|error|refused" ${out}/host.log 2>/dev/null | tail -20; echo ==TAIL==; tail -n 25 ${out}/host.log 2>/dev/null`);
      const raw = (() => { try { return JSON.parse(r.stdout.split("==RAW==")[1].split("==CONV==")[0]); } catch { return {}; } })();
      const res0 = raw?.results?.[0];
      let replies: string[] = (res0?.msgs ?? []).map((m: any) => String(m.text));
      if (!replies.length) { try { replies = JSON.parse(r.stdout.split("==CONV==")[1].split("==HOST==")[0].trim() || "[]"); } catch { /* none */ } }
      writeFileSync(path.join(outDir, `${label}.log`), r.stdout);
      await run(`rm -f ${login}`);
      return { label, exit: done ? "exit 0" : "nonzero or timed out", replies, timeout: res0?.timeout ?? null, why: r.stdout.split("==HOST==")[1]?.split("==TAIL==")[0]?.trim().slice(-600) ?? "" };
    };
    const control = await oneRun("control");
    (report.runs as RunResult[]).push(control);
    say(`control replies: ${JSON.stringify(control.replies)}`);
    const proof = await oneRun("proof");
    (report.runs as RunResult[]).push(proof);
    say(`proof replies: ${JSON.stringify(proof.replies)}`);
    const cOk = judge("control", control);
    const pOk = judge("proof", proof);
    J.record({ step: "control: no opt-in, resolving route: no model reply", status: cOk ? "pass" : "fail", ms: 0, detail: JSON.stringify(control.replies).slice(0, 400) });
    J.record({ step: "proof: opted-in host gets a model reply", status: pOk ? "pass" : "fail", ms: 0, detail: JSON.stringify(proof.replies).slice(0, 400) });
    verdict = pOk && cOk
      ? `PASS: the opted-in Chief replied ${JSON.stringify(proof.replies.join(" ").slice(0, 200))}; the control got no model reply`
      : !pOk ? "FAIL: no model reply from the opted-in Chief" : "FAIL: the control got a model reply, so the route did not take over";
    return pOk && cOk ? 0 : 1;
  } finally {
    if (machine) {
      await remove(machine);
      const m = await api.read("cloud.machine.get", { machine }).catch(() => null);
      report.deleted = !m || m.status === "deleted" || m.status === "deleting";
    }
    write(verdict);
    say(verdict);
  }
}

if (import.meta.main) main().then((c) => process.exit(c), (e) => { console.error(String((e as Error).message ?? e)); process.exit(1); });
