#!/usr/bin/env bun
/**
 * One Chief turn on a cmux Cloud machine of staging, read back (Cloud Chiefs, workstream 12).
 *
 *   bun scripts/cmux-next/cloud-chief-turn-proof.ts --bundle chief.tgz --out DIR
 *
 * Staging machines have no shared model route (cmux-platform CoderouterEdge.ts installs it only in development), so a
 * Chief turn there answered "Claude is not signed in here". optchat-chief now sends its host's Claude credential with
 * its own Claude sessions when the host has OPTCHAT_CHIEF_TURN_CREDENTIALS=1 (src/turn_credential.rs).
 *
 * It signs in as the staging agent test account (CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD), creates a machine named
 * `cmux-test-chief-<tag>`, copies the bundle (an optchat-chief built from this checkout and its measure/ driver) to it
 * through fs/write, and runs measure/chief_driver.py there twice, one turn each ("Reply with exactly one word: OK").
 * Both runs use the machine's own cmux-tui and its own acpmux (the daemon a Cloud chat runs on), and both hosts have
 * CLAUDE_CODE_OAUTH_TOKEN in their environment (a 0600 file the driver deletes). The machine has no Claude sign-in.
 *   control: without the opt-in; expected: the "not signed in" answer.
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
const DIR = `${HOME}/.cmux-chief-proof`;
/** The machine's cmux-tui, as the journey finds it. */
const FIND_CMUX = 'c=$(command -v cmux-tui || true); [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
export const NOT_SIGNED_IN = /not signed in|not logged in/i;

export type RunResult = { label: string; exit: string; replies: string[]; timeout: boolean | null; why: string };

/** A run's verdict: the proof wants a model reply ("OK"), the control the sign-in answer. */
export function judge(label: "control" | "proof", r: RunResult): boolean {
  const text = r.replies.join("\n");
  if (label === "control") return NOT_SIGNED_IN.test(text);
  return /\bok\b/i.test(text) && !NOT_SIGNED_IN.test(text);
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
  const token = (process.env.CLAUDE_CODE_OAUTH_TOKEN ?? "").trim();
  if (!email || !password) throw new Error("no agent test account: CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
  if (!token) throw new Error("no CLAUDE_CODE_OAUTH_TOKEN");
  // `<base36 start time>-<run>`: the sweep below reads the time back.
  const runId = (argValue("--run", argv) ?? "local").replace(/[^a-z0-9]/gi, "").toLowerCase();
  const tag = `${Date.now().toString(36)}-${runId}`;
  const J = new Journey(backend, outDir, { tag });
  J.secrets.push(password, token);
  const say = (line: string) => console.log(scrub(line, J.secrets));
  const report: Record<string, unknown> = { backend: backend.name, tag, runs: [] as RunResult[] };
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
      const a = await api.op("cloud.machine.create", { name: `${NAME_PREFIX}${tag}`, size: { cpu: 4, memory_mb: 8192, disk_mb: 16384 } }, `${tag}-create`);
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
        `getent hosts coderouter.cmux.internal >/dev/null && echo coderouter_resolves || echo coderouter_unresolved; uname -m; ldd --version 2>&1 | head -1`);
      const kv = Object.fromEntries(r.stdout.split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
      if (!kv["cmux-tui"]) throw new Error(`no cmux-tui on the machine: ${r.stdout.slice(0, 400)}`);
      if (!kv.acpmux_socket) throw new Error(`no acpmux socket on the machine: ${r.stdout.slice(0, 400)}`);
      report.facts = r.stdout.trim();
      return { value: kv, detail: r.stdout.trim().replace(/\n/g, "; ").slice(0, 600) };
    });
    // The driver's bins: this checkout's optchat-chief, the machine's cmux-tui, and acpmux as the machine runs it.
    const acpmux = facts.acpmux ? `ln -sf ${shq(facts.acpmux)} ${DIR}/bin/acpmux` : `printf '#!/bin/sh\\nexec %s acp "$@"\\n' ${shq(facts["cmux-tui"])} > ${DIR}/bin/acpmux && chmod +x ${DIR}/bin/acpmux`;
    await run(`ln -sf ${shq(facts["cmux-tui"])} ${DIR}/bin/cmux-tui && ${acpmux}`);
    const oneRun = async (label: "control" | "proof"): Promise<RunResult> => {
      const login = `${DIR}/${label}.login.env`;
      await writeFile(login, Buffer.from(`CLAUDE_CODE_OAUTH_TOKEN=${token}\n`), 0o600);
      const optIn = label === "proof" ? "--env OPTCHAT_CHIEF_TURN_CREDENTIALS=1" : "";
      const out = `${DIR}/${label}`;
      const start = await run(`setsid nohup python3 ${DIR}/measure/chief_driver.py --scenario smoke --only s03 --out ${out} --bins ${DIR}/bin ` +
        `--login-env ${login} --delete-login-env --turn-timeout 240 --max-settle 0 --env ACPMUX_SOCKET=${shq(facts.acpmux_socket)} ${optIn} ` +
        `> ${DIR}/${label}.log 2>&1 < /dev/null & echo started`);
      if (!start.stdout.includes("started")) throw new Error(`start: ${start.stderr.slice(-300)}`);
      const t0 = Date.now();
      let done = false;
      while (Date.now() - t0 < 420_000) {
        await sleep(10_000);
        const r = await run(`pgrep -f "chief_driver.py --scenario smoke --only s03 --out ${out}" >/dev/null && echo running || echo ended`);
        if (r.stdout.includes("ended")) { done = true; break; }
      }
      const r = await run(`tail -c 3000 ${DIR}/${label}.log; echo; echo ==RAW==; cat ${out}/raw.json 2>/dev/null || echo '{}'; echo; echo ==CONV==; ` +
        `python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([" ".join(p.get("text","") for p in m.get("parts",[]) if p.get("type")=="text")[:1500] for m in d.get("messages",[]) if m.get("author")=="agent_mux"]))' ${out}/conversation.json 2>/dev/null; ` +
        `echo ==HOST==; grep -iE "credential|not signed|not logged|turn.end|error" ${out}/host.log 2>/dev/null | tail -20`);
      const raw = (() => { try { return JSON.parse(r.stdout.split("==RAW==")[1].split("==CONV==")[0]); } catch { return {}; } })();
      const res0 = raw?.results?.[0];
      let replies: string[] = (res0?.msgs ?? []).map((m: any) => String(m.text));
      if (!replies.length) { try { replies = JSON.parse(r.stdout.split("==CONV==")[1].split("==HOST==")[0].trim() || "[]"); } catch { /* none */ } }
      writeFileSync(path.join(outDir, `${label}.log`), r.stdout);
      // Never left running on a machine about to be deleted: only the driver this run started.
      if (!done) await run(`pkill -TERM -f "chief_driver.py --scenario smoke --only s03 --out ${out}" || true`);
      return { label, exit: done ? "ended" : "timed out (stopped)", replies, timeout: res0?.timeout ?? null, why: r.stdout.split("==HOST==")[1]?.trim().slice(-600) ?? "" };
    };
    const control = await oneRun("control");
    (report.runs as RunResult[]).push(control);
    say(`control replies: ${JSON.stringify(control.replies)}`);
    const proof = await oneRun("proof");
    (report.runs as RunResult[]).push(proof);
    say(`proof replies: ${JSON.stringify(proof.replies)}`);
    const cOk = judge("control", control);
    const pOk = judge("proof", proof);
    J.record({ step: "control: no opt-in answers not signed in", status: cOk ? "pass" : "fail", ms: 0, detail: JSON.stringify(control.replies).slice(0, 400) });
    J.record({ step: "proof: opted-in host gets a model reply", status: pOk ? "pass" : "fail", ms: 0, detail: JSON.stringify(proof.replies).slice(0, 400) });
    verdict = pOk ? `PASS: the Chief replied ${JSON.stringify(proof.replies.join(" ").slice(0, 200))}${cOk ? " (control: not signed in)" : " (control did not show the sign-in answer)"}` : "FAIL: no model reply from the opted-in Chief";
    return pOk ? 0 : 1;
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
