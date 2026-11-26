#!/usr/bin/env bun
/**
 * `machine.chief_start` on staging: a Chief on its own Cloud machine, started with the cmux-cloud-api call the
 * daemon's `cloud.machine.chief_start` runs (through `--call`, the crate's daemonless `cloud_call` example: the
 * request line on stdin, so no credential is in argv).
 *
 *   1. sign in (the staging agent test account) and sweep this check's machines older than 3 h;
 *   2. the call with `until: "machine"`: the machine `cmux-test-<run>`, running, not yet kept (keep and the idle
 *      policy come only once the host runs, so a start that fails before then leaves no kept machine);
 *   3. this run's optchat-chief into the work user's ~/.local/bin when the machine's image has no Chief host yet;
 *   4. the call again with the same key: pairing (the machine's own `optchat-chief cloud pair`, approved by the
 *      call), the Chief placed on that install, cmux-chief.service enabled and started, and only then the machine
 *      kept with idle_seconds 180 (RFD 0037: it pauses when idle and wakes on a message);
 *   5. a third call with the same key: the same machine and Chief (resume never makes a second one);
 *   6. the host: cmux-chief.service active with one main pid and no restart 20 s on, and the Chief listed as
 *      placed on the machine's install, and `GET /v1/chief/chiefs` listing it with location kind "machine";
 *   7. a message sent the way the Mac and iPhone send (`message.send` on the Chief's conversation) gets a reply
 *      from the Chief within 4 min, and one sent the way the phone's web page sends (`POST /v1/chief/messages`
 *      with `chiefId`, cmux-platform#1637) does too where this Worker serves that route to a bearer;
 *   8. finally: archive the Chief, revoke the install, delete the machine.
 *
 * Usage: bun scripts/cmux-next/cloud-chief-start-check.ts --call PATH --binary PATH [--target staging] [--out DIR] [--run ID]
 * Env: CMUX_DOGFOOD_STACK_EMAIL, CMUX_DOGFOOD_STACK_PASSWORD, PRODUCT_TEAM (optional).
 */
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";
import { Api, directExec, Journey, listAllMachines, passwordSignIn, resolveBackend, STACK, type Exec } from "./cloud-journey";

const NAME_PREFIX = "cmux-test-";
const CHECK_MARK = "-chief-start";
const SWEEP_AFTER_MS = 3 * 60 * 60 * 1000;
const CHUNK = 3 << 20;
const STAGE = "/var/tmp/cmux-chief-start-check";

const arg = (name: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const asRoot = (cmd: string) => `if [ "$(id -u)" = 0 ]; then sh -c ${shq(cmd)}; else sudo -n sh -c ${shq(cmd)}; fi`;

async function must(exec: Exec, cmd: string, timeoutMs = 120_000): Promise<string> {
  const r = await exec(cmd, timeoutMs);
  if (r.code !== 0) throw new Error(`exit ${r.code}: ${(r.stderr || r.stdout).trim().slice(-800)}`);
  return r.stdout.trim();
}

/** One cmux-cloud-api call through `--call`: its answer's body, or the refusal as an error. */
function call(binary: string, request: Record<string, unknown>, timeoutMs: number, tail = ""): Promise<any> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      clearTimeout(timer);
      let line: any;
      try {
        line = JSON.parse(out.trim().split("\n").at(-1) ?? "");
      } catch {
        return reject(new Error(`${request.call}: exit ${code}, no answer line: ${err.trim().slice(-600)}`));
      }
      if (line.ok === true) resolve(line.body);
      else reject(new Error(`${request.call}: ${JSON.stringify(line.error).slice(0, 800)}`));
    });
    // The tail after the first newline is the owner's Claude credential, as the Mac app sends it (cmux-cloud-api
    // chief_turn.rs): never in argv or the request JSON.
    child.stdin.end(tail ? `${JSON.stringify(request)}\n${tail}` : JSON.stringify(request));
  });
}

async function upload(api: Api, machine: string, exec: Exec, data: Buffer, dest: string): Promise<void> {
  await must(exec, asRoot(`rm -rf ${STAGE} && mkdir -p ${STAGE}`));
  const parts: string[] = [];
  for (let off = 0, i = 0; off < data.length; off += CHUNK, i++) {
    const p = `${STAGE}/${String(i).padStart(4, "0")}`;
    const w = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: p, dataBase64: data.subarray(off, off + CHUNK).toString("base64"), mode: 0o644 }, 120_000);
    if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${p}: HTTP ${w.status} ${String(w.body?.error?.code ?? "")}`);
    parts.push(p);
  }
  const sha = createHash("sha256").update(data).digest("hex");
  await must(exec, asRoot(`install -d -o cmux -g cmux -m 0755 "$(dirname ${dest})" && cat ${parts.join(" ")} > ${dest} && chown cmux:cmux ${dest} && chmod 0755 ${dest} && rm -rf ${STAGE} && test "$(sha256sum ${dest} | cut -d' ' -f1)" = ${sha}`));
}

const unitFacts = async (exec: Exec) => {
  const out = await must(exec, "systemctl show cmux-chief.service -p ActiveState -p SubState -p MainPID -p NRestarts");
  return Object.fromEntries(out.split("\n").map((l) => l.split("=", 2) as [string, string]));
};
const journal = (exec: Exec) => exec(asRoot("journalctl -u cmux-chief.service --no-pager -o cat -n 60"), 30_000).then((r) => r.stdout.trim().slice(-2500));
/** What a missing reply leaves on the machine: the Chief's log, the daemon that carries its cloud conversation, its turn traces. */
const replyEvidence = (exec: Exec) =>
  exec(
    asRoot(
      [
        "echo '== cmux-chief.service'; journalctl -u cmux-chief.service --no-pager -o short-iso -n 120 | tail -c 6000",
        "echo '== daemon on the Chief socket'; s=$(head -n 1 /etc/cmux/daemon-socket 2>/dev/null); echo \"socket $s\"; ps -eo pid,etimes,args | grep '[c]mux-tui' | head -5",
        "echo '== journal since 8 min, cloud and daemon lines'; journalctl --no-pager -o short-iso --since '-8 min' | grep -iE 'cmux-tui|cloud|conversation|websocket|subscri|wake|turn|acpmux|claude|error|warn' | grep -v ' sudo' | tail -n 120 | tail -c 9000",
        "echo '== traces'; d=/home/cmux/.cmux/mux/optchat/traces; ls -lt $d 2>/dev/null | head -5; f=$(ls -t $d 2>/dev/null | head -n 1); [ -n \"$f\" ] && tail -c 3000 \"$d/$f\"",
      ].join("; "),
    ),
    60_000,
  ).then((r) => `${r.stdout.trim()}\n${r.stderr.trim().slice(-500)}`, (e) => `(evidence failed: ${String(e).slice(0, 300)})`);

const REPLY_DEADLINE_MS = 240_000;
const rowText = (m: any): string =>
  (Array.isArray(m?.parts) ? m.parts : []).filter((p: any) => p?.type === "text").map((p: any) => String(p.text ?? "")).join("\n") || String(m?.text ?? "");

/** The Chief's first message in its conversation not seen before (the snapshot's newest 50), or null by the deadline. */
async function chiefReply(api: Api, conversation: string, chief: string, seen: Set<string>, deadlineMs: number): Promise<{ text: string } | null> {
  const until = Date.now() + deadlineMs;
  for (;;) {
    const snap = await api.read("conversation.snapshot", { conversation, tail: 50 });
    const rows = (snap?.rows?.rows ?? []).map((r: any) => r?.row ?? r);
    for (const m of rows) {
      const who = String(m?.author ?? m?.sender ?? m?.sender_id ?? "");
      const id = String(m?.id ?? m?.message_id ?? m?.seq ?? "");
      if (who !== chief || seen.has(id)) continue;
      const text = rowText(m);
      if (!text.trim()) continue;
      seen.add(id);
      return { text };
    }
    if (Date.now() >= until) return null;
    await sleep(3_000);
  }
}

const rowsSeen = (api: Api, conversation: string) =>
  api.read("conversation.snapshot", { conversation, tail: 8 }).then(
    (snap) => JSON.stringify((snap?.rows?.rows ?? []).map((r: any) => r?.row ?? r).map((m: any) => `${m?.author ?? m?.sender ?? "?"}: ${rowText(m).slice(0, 60)}`)),
    (e) => `(snapshot failed: ${String(e).slice(0, 200)})`,
  );

async function main(): Promise<number> {
  const callPath = arg("--call");
  const binaryPath = arg("--binary");
  if (!callPath || !binaryPath) throw new Error("--call PATH (cmux-cloud-api's cloud_call) and --binary PATH (x86_64 Linux optchat-chief) are required");
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD are required (never a skip)");
  const backend = resolveBackend(arg("--target") ?? "staging");
  const run = arg("--run") ?? `${process.env.GITHUB_RUN_ID ?? Date.now()}-${process.env.GITHUB_RUN_ATTEMPT ?? "1"}`;
  const outDir = arg("--out") ?? null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const J = new Journey(backend, outDir, { check: "cloud-chief-start", run });
  J.secrets.push(password);
  const team = process.env.PRODUCT_TEAM || undefined;
  const api = new Api(backend.api, team);
  const key = `t${run}`.toLowerCase().replace(/[^a-z0-9-]/g, "-").slice(0, 48);
  const machineName = `${NAME_PREFIX}${run}${CHECK_MARK}`.slice(0, 64);
  let machine = "";
  let install = "";
  let chief = "";
  // The owner's Claude login, sent with chief_start the way the Mac app sends the person's Claude connection.
  const turnEnv = Object.fromEntries(["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"].filter((n) => process.env[n]).map((n) => [n, process.env[n]!]).slice(0, 1));
  const turnTail = Object.keys(turnEnv).length ? JSON.stringify({ env: turnEnv }) : "";
  for (const v of Object.values(turnEnv)) J.secrets.push(v);
  const start = (until?: string) =>
    call(callPath, {
      call: "machine.chief_start", api: backend.api, auth: "owner", credential: api.bearer, ...(team ? { team } : {}),
      args: { key, name: "Check Chief", machine_name: machineName, ...(until ? { until } : {}) },
    }, 1_500_000, turnTail);
  try {
    await J.step("sign in", async () => {
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      api.bearer = s.access;
      await api.op("user.ensure", {}, `chief-start-${run}-ensure`);
      return { value: null, detail: backend.api };
    });
    await J.step("sweep old check machines", async () => {
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
      const old = rows.filter((r) => String(r?.name ?? "").startsWith(NAME_PREFIX) && String(r?.name ?? "").endsWith(CHECK_MARK) && r.status !== "deleted" && r.status !== "deleting" && typeof r.created_at === "number" && Date.now() - r.created_at > SWEEP_AFTER_MS);
      for (const r of old) await api.deleteMachine(String(r.id ?? r.machine_id), `chief-start-sweep-${r.id ?? r.machine_id}`).catch(() => undefined);
      return { value: null, detail: `${old.length} older than 3 h deleted` };
    });
    const t0 = Date.now();
    await J.step("chief_start until machine (create, not kept yet)", async () => {
      const a = await start("machine");
      machine = String(a.machine);
      if (a.stage !== "machine" || !machine.startsWith("vm_")) throw new Error(`unexpected answer ${JSON.stringify(a)}`);
      const m = await api.read("cloud.machine.get", { machine });
      const row = m?.machine ?? m;
      if (row?.keep === true) throw new Error("kept before its host runs");
      return { value: null, detail: `${machineName} ${machine}, idle_policy ${JSON.stringify(row?.idle_policy ?? null)}, keep ${row?.keep}` };
    });
    const exec = directExec(api, machine, J);
    await J.step("Chief host on the machine", async () => {
      const r = await exec("command -v optchat-chief || test -x /home/cmux/.local/bin/optchat-chief && echo local || echo absent");
      const found = r.stdout.trim().split("\n").at(-1) ?? "";
      // An image baked before cmux#56352 has a unit that never reads the turn credential chief_start writes.
      const unit = await exec("grep -c turn.env /etc/systemd/system/cmux-chief.service 2>/dev/null || echo 0");
      const reads = (unit.stdout.trim().split("\n").at(-1) ?? "0") !== "0" ? "reads" : "does not read";
      if (found !== "absent") return { value: null, detail: `image has ${found}; its unit ${reads} /run/cmux-chief/turn.env; credential sent: ${Object.keys(turnEnv).join(",") || "none"}` };
      await upload(api, machine, exec, readFileSync(binaryPath), "/home/cmux/.local/bin/optchat-chief");
      return { value: null, detail: "absent from the image: this run's build in ~/.local/bin" };
    });
    const done = await J.step("chief_start again, same key (pair, place, start the host, keep, idle 180)", async () => {
      const a = await start();
      if (a.stage !== "done" || a.machine !== machine || !a.chief || !a.install) throw new Error(`unexpected answer ${JSON.stringify(a)}`);
      install = a.install;
      chief = a.chief;
      const m = await api.read("cloud.machine.get", { machine });
      const row = m?.machine ?? m;
      if (row?.keep !== true) throw new Error(`keep is ${JSON.stringify(row?.keep)}`);
      if (row?.idle_policy?.idle_seconds !== 180) throw new Error(`idle_policy is ${JSON.stringify(row?.idle_policy ?? null)}, not idle_seconds 180`);
      return { value: a, detail: `chief ${a.chief}, conversation ${a.conversation}, install ${a.install}, unit ${a.host_unit}` };
    });
    const startSeconds = Math.round((Date.now() - t0) / 1000);
    await J.step("chief_start a third time: the same machine and Chief", async () => {
      const a = await start();
      if (a.machine !== machine || a.chief !== done.chief) throw new Error(`a second machine or Chief: ${JSON.stringify(a)}`);
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
      const same = rows.filter((r) => r?.name === machineName && r.status !== "deleted" && r.status !== "deleting");
      if (same.length !== 1) throw new Error(`${same.length} machines named ${machineName}`);
      return { value: null, detail: `one machine, one Chief; start took ${startSeconds} s` };
    });
    await J.step("the Chief host runs and stays up", async () => {
      const a = await unitFacts(exec);
      await sleep(20_000);
      const b = await unitFacts(exec);
      if (b.ActiveState !== "active" || a.MainPID !== b.MainPID || b.MainPID === "0") {
        throw new Error(`not steady: ${JSON.stringify(a)} then ${JSON.stringify(b)}\n${await journal(exec)}`);
      }
      const listed = await api.read("chief.list", {});
      const row = (listed?.chiefs ?? []).find((c: any) => c?.id === chief);
      if (row?.brain_place?.install !== install) throw new Error(`chief ${chief} is not placed on ${install}: ${JSON.stringify(row?.brain_place ?? null)}`);
      return { value: null, detail: `active, pid ${b.MainPID}, restarts ${b.NRestarts}; ${chief} placed on ${install}` };
    });
    await J.step("the Chief lists as running on its machine (GET /v1/chief/chiefs)", async () => {
      const r = await api.raw("GET", "/v1/chief/chiefs", undefined, 30_000);
      // The route is cmux-platform#1635's; until it deploys, a 404 says so and the step passes on chief.list above.
      if (r.status === 404) return { value: null, detail: "GET /v1/chief/chiefs not deployed yet (404)" };
      if (r.status !== 200) throw new Error(`GET /v1/chief/chiefs: HTTP ${r.status} ${JSON.stringify(r.body).slice(0, 400)}`);
      const row = (r.body?.chiefs ?? []).find((c: any) => c?.chiefId === chief);
      const at = row?.location;
      if (at?.kind !== "machine" || at?.install !== install) throw new Error(`chief ${chief} lists as ${JSON.stringify(at ?? null)}, not on machine install ${install}`);
      return { value: null, detail: `${chief}: location machine, host ${at.host}, install ${at.install}` };
    });
    const conversation = String(done.conversation ?? "");
    const seen = new Set<string>();
    await J.step("a message from the app gets the Chief's reply (message.send, as the Mac and iPhone send)", async () => {
      if (!conversation) throw new Error(`chief_start answered no conversation: ${JSON.stringify(done)}`);
      const word = `pong-${run}`;
      const sentAt = Date.now();
      await api.op("message.send", { conversation, client_msg_id: `chief-start-${run}-app`, parts: [{ type: "text", text: `Reply with only the word ${word}` }] }, `chief-start-${run}-app`);
      const reply = await chiefReply(api, conversation, chief, seen, REPLY_DEADLINE_MS);
      if (!reply) throw new Error(`no reply from ${chief} in ${REPLY_DEADLINE_MS / 1000} s; newest rows ${await rowsSeen(api, conversation)}\n${await replyEvidence(exec)}`);
      if (/not signed in|not logged in/i.test(reply.text)) throw new Error(`the Chief answered without a model: ${reply.text.slice(0, 300)}`);
      return { value: null, detail: `reply in ${Math.round((Date.now() - sentAt) / 1000)} s: ${JSON.stringify(reply.text.slice(0, 200))}${reply.text.includes(word) ? "" : " (did not echo the word)"}` };
    });
    await J.step("a message from the phone's web page gets the reply (POST /v1/chief/messages with chiefId)", async () => {
      const sentAt = Date.now();
      const r = await api.raw("POST", "/v1/chief/messages", { chiefId: chief, text: "Reply with only the word again", clientMessageId: `chief-start-${run}-web` }, 30_000);
      // The platform's /c/ surface (cmux-platform#1637) signs in with its page cookie; where this Worker does not
      // serve it to a bearer, the step says so and the reply check above stands.
      if (r.status === 404 || r.status === 401 || r.status === 403) return { value: null, detail: `POST /v1/chief/messages answered HTTP ${r.status} to a bearer on ${backend.api}; not read here` };
      if (r.status !== 200 || r.body?.ok !== true) throw new Error(`POST /v1/chief/messages: HTTP ${r.status} ${JSON.stringify(r.body).slice(0, 400)}`);
      const reply = await chiefReply(api, conversation, chief, seen, REPLY_DEADLINE_MS);
      if (!reply) throw new Error(`no reply from ${chief} in ${REPLY_DEADLINE_MS / 1000} s`);
      return { value: null, detail: `reply in ${Math.round((Date.now() - sentAt) / 1000)} s: ${JSON.stringify(reply.text.slice(0, 200))}` };
    });
    return J.steps.some((s) => s.status === "fail") ? 1 : 0;
  } catch (e) {
    console.error(`cloud-chief-start-check: ${String((e as Error)?.message ?? e).slice(0, 2000)}`);
    return 1;
  } finally {
    if (chief) {
      await J.step("archive the Chief", async () => {
        const row = ((await api.read("chief.list", {}))?.chiefs ?? []).find((c: any) => c?.id === chief);
        if (row) await api.op("chief.archive", { chief, expected_rev: row.rev }, `chief-start-${run}-archive`);
        return { value: null, detail: chief };
      }).catch(() => undefined);
    }
    if (install) {
      await J.step("revoke the install", async () => {
        await api.op("install.revoke", { install }, `chief-start-${run}-revoke`);
        return { value: null, detail: install };
      }).catch(() => undefined);
    }
    await J.step("delete machine", async () => {
      // A call that failed after its create answers no id: the machine is found by this run's name.
      const ids = machine ? [machine] : (await listAllMachines((p) => api.read("cloud.machine.list", p)))
        .filter((r) => r?.name === machineName && r.status !== "deleted" && r.status !== "deleting")
        .map((r) => String(r.id ?? r.machine_id));
      for (const id of ids) await api.deleteMachine(id, `chief-start-${run}-delete-${id}`);
      return { value: null, detail: ids.join(", ") || "none made" };
    }).catch(() => undefined);
  }
}

process.exit(await main());
