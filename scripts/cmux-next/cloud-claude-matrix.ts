#!/usr/bin/env bun
/**
 * Cloud chat matrix: Claude. Every way a person signs Claude in, on every model, through every kind of chat, against
 * one backend, with the reply read back (Leo, 2026-11-10: "Does it work across every expected possible workspace?").
 *
 *   bun scripts/cmux-next/cloud-claude-matrix.ts --backend prod --credentials ~/.secrets/cmuxterm-prod.env --out DIR
 *   bun scripts/cmux-next/cloud-claude-matrix.ts --backend prod --auth sr2 --models sonnet --out DIR
 *   bun scripts/cmux-next/cloud-claude-matrix.ts --plan            # the cells and why each would skip, no machines
 *
 * Rows are auth x model; columns are the chats. Each row is one cloud-journey.ts run (`--agent claude/MODEL`) on its
 * own new machine, which the journey deletes by exact id, pass or fail; the rows of one auth run at once (at most
 * --parallel machines, default 3), and that concurrency is the "two chats in parallel" column: it passes when at
 * least two concurrent rows read a first reply back.
 *
 *   first     the first chat on a new machine            (journey step `reply`, and `session model` when reported)
 *   followup  a second turn in the same session          (`turn 2 (same session)`)
 *   resume    a turn after the machine paused and resumed (`turn after resume`)
 *   parallel  the auth's rows running at once            (their `reply` steps)
 *
 * Times: `create→reply` is from the start of `create machine` to the end of `reply`; `reply` is the send-to-reply
 * time of the first chat, the time to first token as the journey sees it (it reads whole replies, not a stream).
 *
 * Auth:
 *   sr2           no login passed: the machine's team mode, the SR2/CodeRouter gateway (the default)
 *   subscription  a Claude Pro/Max login, CLAUDE_CODE_OAUTH_TOKEN (the Mac's login copy; dev and dogfood only)
 *   api-key       ANTHROPIC_API_KEY, put in Claude's settings on the machine (the chat card's API-key route)
 *   team-key      a key from the team's settings (CMUX_MATRIX_TEAM_KEY_TEAM names the team that has one)
 * A row whose credential is absent is SKIP with the reason, never a pass. Exit 0 only when no run cell failed.
 * Secrets come from the environment or --credentials only and are never printed (the journey scrubs its output).
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readEnvFile, type Step } from "./cloud-journey.ts";

export const MODELS: Record<string, string> = { opus: "claude-opus-5-5", sonnet: "claude-sonnet-5-5", haiku: "claude-haiku-5-5" };
export const AUTHS = ["sr2", "subscription", "api-key", "team-key"] as const;
export type Auth = (typeof AUTHS)[number];
export const CHATS = ["first", "followup", "resume", "parallel"] as const;
export type Chat = (typeof CHATS)[number];
export type CellStatus = "pass" | "fail" | "skip";
export type Cell = { status: CellStatus; detail: string };
export type Row = { auth: Auth; model: string; cells: Record<Chat, Cell>; replyMs?: number; createToReplyMs?: number; reply?: string };

const STEP: Record<Exclude<Chat, "parallel">, string> = { first: "reply", followup: "turn 2 (same session)", resume: "turn after resume" };

/** Why a row of this auth cannot run here, or null when it can. */
export function authBlocker(auth: Auth, env: Record<string, string | undefined>): string | null {
  switch (auth) {
    case "sr2":
      return null;
    case "subscription":
      return env.CLAUDE_CODE_OAUTH_TOKEN ? null : "no CLAUDE_CODE_OAUTH_TOKEN (a Claude Pro/Max login) in the environment";
    case "api-key":
      return env.ANTHROPIC_API_KEY ? "the journey has no API-key leg yet (the chat card's api_key route is not driven headless)" : "no ANTHROPIC_API_KEY in the environment";
    case "team-key":
      return env.CMUX_MATRIX_TEAM_KEY_TEAM ? "the journey has no team-key leg yet" : "no team with a key in its settings (CMUX_MATRIX_TEAM_KEY_TEAM)";
  }
}

/** One row's cells from its journey steps (the parallel cell is filled in by [`parallelCell`]). */
export function rowFromSteps(auth: Auth, model: string, steps: Step[], exitCode: number): Row {
  const by = new Map(steps.map((s) => [s.step, s]));
  const cells = {} as Record<Chat, Cell>;
  const firstFailed = steps.find((s) => s.status === "fail");
  for (const chat of ["first", "followup", "resume"] as const) {
    const s = by.get(STEP[chat]);
    if (!s) cells[chat] = { status: "fail", detail: firstFailed ? `not reached: ${firstFailed.step} failed: ${firstFailed.detail.slice(0, 200)}` : `no ${STEP[chat]} step (journey exit ${exitCode})` };
    else cells[chat] = { status: s.status, detail: s.detail.slice(0, 200) };
  }
  const modelStep = by.get("session model");
  if (modelStep?.status === "fail" && cells.first.status === "pass") cells.first = { status: "fail", detail: modelStep.detail };
  cells.parallel = { status: "skip", detail: "not run in parallel" };
  const create = steps.findIndex((s) => s.step === "create machine");
  const reply = steps.findIndex((s) => s.step === "reply");
  const row: Row = { auth, model, cells };
  if (reply >= 0 && steps[reply].status === "pass") {
    row.replyMs = steps[reply].ms;
    row.reply = steps[reply].detail.slice(0, 120);
    if (create >= 0 && create < reply) row.createToReplyMs = steps.slice(create, reply + 1).reduce((n, s) => n + s.ms, 0);
  }
  return row;
}

/** The parallel cell of rows that ran at once: a pass when at least two of them read a first reply back. */
export function parallelCell(rows: Row[]): Cell {
  if (rows.length < 2) return { status: "skip", detail: "fewer than two rows ran at once" };
  const ok = rows.filter((r) => r.cells.first.status === "pass").length;
  return ok >= 2 ? { status: "pass", detail: `${ok} of ${rows.length} concurrent chats replied` } : { status: "fail", detail: `${ok} of ${rows.length} concurrent chats replied` };
}

const sec = (ms?: number) => (ms === undefined ? "" : `${(ms / 1000).toFixed(1)} s`);
const mark = (c: Cell) => (c.status === "pass" ? "pass" : c.status === "fail" ? "**FAIL**" : "skip");

export function matrixMarkdown(backend: string, rows: Row[]): string {
  const failed = rows.some((r) => CHATS.some((c) => r.cells[c].status === "fail"));
  const lines = [
    `${failed ? "FAIL" : "PASS"}: Cloud chat matrix, Claude, on \`${backend}\``,
    "",
    "| auth | model | first | follow-up | resume | parallel | reply (send→reply) | create→reply | reply read back |",
    "|---|---|---|---|---|---|---:|---:|---|",
    ...rows.map((r) => `| ${r.auth} | ${r.model} | ${CHATS.map((c) => mark(r.cells[c])).join(" | ")} | ${sec(r.replyMs)} | ${sec(r.createToReplyMs)} | ${(r.reply ?? "").replace(/\|/g, "\\|").replace(/\n/g, " ")} |`),
    "",
  ];
  const notes = rows.flatMap((r) => CHATS.filter((c) => r.cells[c].status !== "pass").map((c) => `- ${r.auth} ${r.model} ${c}: ${r.cells[c].status}: ${r.cells[c].detail.replace(/\n/g, " ")}`));
  return [...lines, ...(notes.length ? ["Why each non-pass cell is what it is:", "", ...notes, ""] : [])].join("\n");
}

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** One journey run; its steps from journey.json (empty when it wrote none). */
function runJourney(args: string[], env: Record<string, string | undefined>, outDir: string): Promise<{ code: number; steps: Step[] }> {
  const journey = path.join(path.dirname(fileURLToPath(import.meta.url)), "cloud-journey.ts");
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [journey, ...args, "--out", outDir], { env: env as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "pipe"] });
    const tag = path.basename(outDir);
    const relay = (chunk: Buffer) => { for (const line of chunk.toString().split("\n").filter(Boolean)) console.log(`[${tag}] ${line}`); };
    child.stdout.on("data", relay);
    child.stderr.on("data", relay);
    child.on("close", (code) => {
      const file = path.join(outDir, "journey.json");
      let steps: Step[] = [];
      try { if (existsSync(file)) steps = JSON.parse(readFileSync(file, "utf8")).steps ?? []; } catch { /* unreadable: no steps */ }
      resolve({ code: code ?? 1, steps });
    });
  });
}

async function main(argv: string[]): Promise<number> {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
  }
  const backend = argValue("--backend", argv) ?? "prod";
  const credFile = argValue("--credentials", argv);
  const creds = credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {};
  const env: Record<string, string | undefined> = { ...creds, ...process.env };
  const auths = (argValue("--auth", argv) ?? AUTHS.join(",")).split(",").filter(Boolean) as Auth[];
  const models = (argValue("--models", argv) ?? Object.keys(MODELS).join(",")).split(",").filter(Boolean);
  const parallel = Math.max(1, Math.min(3, Number(argValue("--parallel", argv) ?? 3)));
  const out = argValue("--out", argv) ?? path.join(process.env.RUNNER_TEMP ?? "/tmp", `cloud-claude-matrix-${Date.now().toString(36)}`);
  mkdirSync(out, { recursive: true });
  for (const a of auths) if (!AUTHS.includes(a)) throw new Error(`--auth ${a}: one of ${AUTHS.join(", ")}`);
  for (const m of models) if (!MODELS[m]) throw new Error(`--models ${m}: one of ${Object.keys(MODELS).join(", ")}`);
  const extra = ["--chat-timeout", argValue("--chat-timeout", argv) ?? "300", ...(argValue("--cmux", argv) ? ["--cmux", argValue("--cmux", argv)!] : [])];
  const rows: Row[] = [];
  for (const auth of auths) {
    const blocked = authBlocker(auth, env);
    if (blocked || argv.includes("--plan")) {
      for (const model of models) {
        const cell: Cell = { status: "skip", detail: blocked ?? "--plan: not run" };
        rows.push({ auth, model, cells: { first: cell, followup: cell, resume: cell, parallel: cell } });
      }
      continue;
    }
    const authEnv: Record<string, string | undefined> = { ...env };
    if (auth === "sr2") delete authEnv.CLAUDE_CODE_OAUTH_TOKEN;
    const authRows: Row[] = [];
    for (let i = 0; i < models.length; i += parallel) {
      const batch = models.slice(i, i + parallel);
      const runs = batch.map(async (model, k) => {
        await sleep(k * 1500); // the journey tags its machine with the start time: no two runs in one millisecond
        const dir = path.join(out, `${auth}-${model}`);
        mkdirSync(dir, { recursive: true });
        const args = ["--backend", backend, "--agent", `claude/${MODELS[model]}`, "--prompt", `Reply with one short sentence that says matrix ${auth} ${model} is here.`, ...extra];
        if (credFile) args.push("--credentials", credFile);
        const { code, steps } = await runJourney(args, authEnv, dir);
        return rowFromSteps(auth, model, steps, code);
      });
      const done = await Promise.all(runs);
      const p = parallelCell(done);
      for (const r of done) r.cells.parallel = p;
      authRows.push(...done);
    }
    rows.push(...authRows);
  }
  const md = matrixMarkdown(backend, rows);
  writeFileSync(path.join(out, "matrix.json"), `${JSON.stringify({ backend, at: new Date().toISOString(), rows }, null, 2)}\n`);
  writeFileSync(path.join(out, "matrix.md"), md);
  console.log(md);
  return rows.some((r) => CHATS.some((c) => r.cells[c].status === "fail")) ? 1 : 0;
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)));
