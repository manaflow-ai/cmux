#!/usr/bin/env bun
/**
 * The Cloud chat matrix: one Cloud journey (cloud-journey.ts) per agent and sign-in, each a first
 * chat, a follow-up, a pause and a resume with a turn after it, read back with its timings.
 * Leo, 2026-11-10: "I want to be able to have that work for if somebody has a ChatGPT subscription
 * or a Cursor subscription".
 *
 *   bun scripts/cmux-next/cloud-chat-matrix.ts --backend prod --credentials ~/.secrets/cmuxterm-prod.env
 *   bun scripts/cmux-next/cloud-chat-matrix.ts --cells codex-chatgpt-stub,gemini-signed-out --out /tmp/matrix
 *   bun scripts/cmux-next/cloud-chat-matrix.ts --list
 *
 * Cells run one after another, never at once: journeys on one account at the same time collide on its
 * install token (`install.register`: idempotency.conflict, 2026-11-10). Each cell says how it proves
 * its agent and sign-in:
 *   live     the real model, through the person's sign-in or the team's model plane;
 *   stubbed  the shared model stub on the machine stands in for the model; the sign-in is passed as the
 *            app passes it and every model request must carry it;
 *   expect   a cell whose right answer is a refusal: a signed-out agent must fail fast with its sign-in
 *            error (the chat's Sign in card), never hang.
 * A cell that needs a credential it does not have (CODEX_AUTH_JSON) is skipped and says so.
 *
 * Other lanes add their cells to CELLS (the Claude cells: lane cloud-claude-matrix). --out DIR gets one
 * folder per cell (journey.json, summary.md) and matrix.md, the table for the results issue. Exit 0 only
 * when no cell failed.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PUSH_STEP, REPLY_STEP } from "./cloud-memory-codeword.ts";

export type Cell = {
  id: string;
  agent: string;
  signIn: string;
  proof: "live" | "stubbed" | "expect" | "start" | "bench";
  args: string[];
  /** Environment the cell needs (one name or several); any absent, the cell is skipped with this reason. */
  needs?: { env: string | string[]; why: string };
  /** Journey steps that must run and pass: a skipped one fails the cell, so a cell never passes without its proof. */
  must?: string[];
  /** For `expect` cells: the step that must fail, its error, and the most it may take. */
  expect?: { step: string; error: RegExp; withinMs: number };
};

/**
 * The harnesses the Cloud chat picker offers: the app's LOGIN_AGENTS (cloudAgentLogin.ts), opencode and antigravity
 * (`agy acp`, signed in with Gemini's key: cloudAgentLogin.ts SIGNS_IN_AS). Leo, 2026-11-25: "we'll want to set up
 * antigravity/antigravity cli and opencode capable if we didn't already and stuff".
 */
export const PICKER_HARNESSES = ["claude", "codex", "gemini", "grok", "cursor", "opencode", "antigravity"] as const;

export const CELLS: Cell[] = [
  {
    id: "codex-chatgpt-stub",
    agent: "codex",
    signIn: "ChatGPT subscription (codex login), the app's copy",
    proof: "stubbed",
    args: ["--agent", "codex", "--model", "stub"],
  },
  {
    id: "codex-chatgpt-live",
    agent: "codex",
    signIn: "ChatGPT subscription (codex login), the app's copy",
    proof: "live",
    args: ["--agent", "codex"],
    needs: { env: "CODEX_AUTH_JSON", why: "a Codex ChatGPT sign-in (auth.json) of the test account's own" },
  },
  {
    id: "codex-github-live",
    agent: "codex",
    signIn: "ChatGPT subscription (codex login), the app's copy",
    proof: "live",
    // cloud-journey's live GitHub step asks this agent to clone, branch, commit, push and open a draft PR.
    args: ["--agent", "codex"],
    needs: { env: ["CODEX_AUTH_JSON", "CMUX_JOURNEY_GITHUB_REPO"], why: "a Codex ChatGPT sign-in (auth.json) and the GitHub sandbox repository for the live GitHub agent cell" },
    // cloud-journey.ts's names (JOURNEY_ONLY_STEPS); the matrix test holds them to it.
    must: ["GitHub on the machine (live)", "GitHub by the agent (live)"],
  },
  {
    id: "codex-model-plane",
    agent: "codex",
    signIn: "none: the team's model plane (the API-key route)",
    proof: "live",
    args: ["--agent", "codex"],
  },
  {
    id: "codex-gateway-stub",
    agent: "codex",
    signIn: "none on the machine: the team's inference gateway (a second machine) in front of a stand-in proxy",
    proof: "stubbed",
    args: ["--agent", "codex", "--gateway", "$CMUX_BIN"],
    needs: { env: "CMUX_BIN", why: "a cmux CLI for `cmux inference setup --gateway-machine`" },
  },
  // Lane cloud-grok-gemini-opencode. Under each Cloud cell, acp-agent-contract.py proves the agent's own ACP
  // with no account (first, follow-up, session/load resume; the signed-out refusal).
  {
    id: "opencode-zen",
    agent: "opencode",
    signIn: "none: OpenCode's free Zen models",
    proof: "live",
    args: ["--agent", "opencode", "--lifecycle"],
  },
  {
    id: "gemini-signed-out",
    agent: "gemini",
    signIn: "none: must fail fast with Gemini CLI's sign-in error",
    proof: "expect",
    args: ["--agent", "gemini", "--skip", "lifecycle", "--chat-timeout", "120"],
    expect: { step: "reply", error: /authenticat|auth.?required|not (?:logged|signed) in|log ?in|sign ?in|api key/i, withinMs: 60_000 },
  },
  {
    // Antigravity's ACP answers `session/new` with "Authentication required" until it is signed in (Google, or
    // `authenticate` with a Gemini key); acpmux sends that refusal as the start's sign-in error.
    id: "antigravity-signed-out",
    agent: "antigravity",
    signIn: "none: must fail fast with Antigravity's sign-in error",
    proof: "expect",
    args: ["--agent", "antigravity", "--skip", "lifecycle", "--chat-timeout", "120"],
    expect: { step: "start agent (antigravity)", error: /authenticat|auth.?required|not (?:logged|signed) in|log ?in|sign ?in|api key/i, withinMs: 60_000 },
  },
  // No Cursor, Grok (SuperGrok, xAI key) or third-party provider-key cells: Leo has none of those accounts (Leo,
  // 2026-11-10: "I only have ChatGPT and Google ... Or else I ask the company to get me basic accounts later").
  // The `start` cells below need no account: a signed-out agent passes by naming itself.
  ...PICKER_HARNESSES.map(appStartCell),
  // Agent memory follows the person (hq plans/cloud/agent-memory-follows-user.md step 5, cloud-memory-codeword.ts): a
  // user CLAUDE.md with this run's codeword, pushed from a device home to the person's AgentHome, then a fresh Cloud
  // chat started the app's way; it passes only when the first reply names the codeword.
  {
    id: "claude-memory-codeword",
    agent: "claude",
    signIn: "the machine's own (team gateway): the codeword comes only from the carried CLAUDE.md",
    proof: "live",
    args: ["--agent", "claude", "--start-via", "app", "--cmux", "$CMUX_BIN", "--memory-codeword"],
    needs: { env: "CMUX_BIN", why: "a cmux CLI for the push and the carrier dial the app's start goes over" },
    must: [PUSH_STEP, REPLY_STEP],
  },
  // Not a chat: the start bench (cloud-journey.ts --start-bench, cloud-start-bench.ts), create-to-first-command phase
  // by phase on the spare, cold, snapshot and VM API paths, 5 starts each. Dispatch it alone (cells=start-bench): it
  // makes and deletes about 27 machines and runs 30 to 60 minutes. Leo, 2026-11-16: "let's do all those".
  {
    id: "start-bench",
    agent: "claude",
    signIn: "none needed: no agent is started",
    proof: "bench",
    args: ["--preclaim", "--start-bench", "5", "--cmux", "$CMUX_BIN"],
    needs: { env: "CMUX_BIN", why: "a cmux CLI for the warm the app sends (the spare path)" },
  },
  // TODO(hq#11225 PR4): gemini and grok through the team's inference gateway (a second machine), once gateway
  // routing for those harnesses lands: a started session there, never sign_in_required.
];

/**
 * A fresh machine, each harness the Cloud chat picker offers, started the way the app starts it
 * (`agent-session-start` over the carrier, cloud-journey.ts `--start-via app`). Leo, 2026-11-15: "so does cloud work?
 * on our thing? just automatically? or switching environments? claude and codex alike, through gui? and other
 * harnesses/etc too? and alternatively can pick enviornments?" (hq#11225). Pass: a started session, or exactly
 * `agent_session.sign_in_required` naming that harness (the app then offers that agent's own sign-in); a bare refusal,
 * a hang or another harness's name fails. Mirrors cmux-tui's cloud_harness_start.rs test and the app's LOGIN_AGENTS
 * (webviews/src/agent-session/acpmux/cloudAgentLogin.ts), plus opencode.
 */
function appStartCell(harness: string): Cell {
  return {
    id: `${harness}-app-start`,
    agent: harness,
    signIn: "whatever a fresh machine has: started, or sign_in_required naming the harness",
    proof: "start",
    args: ["--agent", harness, "--start-via", "app", "--cmux", "$CMUX_BIN"],
    needs: { env: "CMUX_BIN", why: "a cmux CLI for the carrier dial the app's start goes over" },
  };
}

/** What the journey's `start agent (H)` step says of the app's start (cloud-journey.ts `--start-via app`). */
export function appStartDetail(reply: any): { ok: boolean; detail: string } {
  if (reply?.ok === true) {
    const session = String(reply?.data?.session ?? "");
    return session ? { ok: true, detail: `started: session ${session}` } : { ok: false, detail: `started with no session: ${JSON.stringify(reply).slice(0, 200)}` };
  }
  const code = String(reply?.error_code ?? reply?.error?.code ?? "no error_code");
  const harness = typeof reply?.data?.harness === "string" ? reply.data.harness : "-";
  return { ok: false, detail: `refused: ${code} harness=${harness}: ${String(reply?.error?.message ?? reply?.error ?? "").slice(0, 160)}` };
}

/** The steps a row reports, with their latencies. */
const TIMED = ["create machine", "reply", "turn 2 (same session)", "pause", "resume", "turn after resume"] as const;

type Step = { step: string; status: "pass" | "fail" | "skip"; ms: number; detail?: string };

export type Row = { cell: Cell; verdict: "pass" | "fail" | "skip"; why: string; ms: Partial<Record<(typeof TIMED)[number], number>>; reply?: string };

/** A cell's verdict from its journey's steps. */
export function judge(cell: Cell, steps: Step[], exit: number): Row {
  const ms: Row["ms"] = {};
  for (const name of TIMED) {
    const s = steps.find((x) => x.step === name && x.status === "pass");
    if (s) ms[name] = s.ms;
  }
  const reply = steps.find((x) => x.step === "reply" && x.status === "pass")?.detail;
  const failed = steps.filter((x) => x.status === "fail" && !x.step.startsWith("prod:"));
  if (cell.proof === "start") {
    // The app's start: a session, or exactly sign_in_required naming this harness. Any other failure fails it.
    const name = `start agent (${cell.agent})`;
    const s = steps.find((x) => x.step === name);
    const others = failed.filter((x) => x.step !== name);
    if (others.length) return { cell, verdict: "fail", why: `${others[0]!.step}: ${(others[0]!.detail ?? "").slice(0, 200)}`, ms };
    if (!s || s.status === "skip") return { cell, verdict: "fail", why: `${name} did not run: ${(s?.detail ?? "not run").slice(0, 200)}`, ms };
    const detail = s.detail ?? "";
    if (s.status === "pass" && detail.startsWith("started: session ")) return { cell, verdict: "pass", why: `${detail.slice(0, 160)} in ${s.ms} ms`, ms };
    const named = /^refused: agent_session\.sign_in_required harness=(\S+):/.exec(detail);
    if (s.status === "fail" && named?.[1] === cell.agent) return { cell, verdict: "pass", why: `signed out, named ${cell.agent} in ${s.ms} ms`, ms };
    return { cell, verdict: "fail", why: `${name}: ${detail.slice(0, 200)}`, ms };
  }
  if (cell.expect) {
    const want = cell.expect;
    const s = steps.find((x) => x.step === want.step);
    // The only failure must be the expected one: an earlier step failing proves nothing about sign-in.
    const others = failed.filter((x) => x.step !== want.step);
    if (others.length) return { cell, verdict: "fail", why: `${others[0]!.step}: ${(others[0]!.detail ?? "").slice(0, 200)}`, ms };
    if (!s || s.status !== "fail") return { cell, verdict: "fail", why: `${want.step} did not fail: ${(s?.detail ?? "not run").slice(0, 200)}`, ms };
    if (!want.error.test(s.detail ?? "")) return { cell, verdict: "fail", why: `${want.step} failed another way: ${(s.detail ?? "").slice(0, 200)}`, ms };
    if (s.ms > want.withinMs) return { cell, verdict: "fail", why: `the sign-in error took ${s.ms} ms (at most ${want.withinMs})`, ms };
    return { cell, verdict: "pass", why: `signed out, refused in ${s.ms} ms: ${(s.detail ?? "").slice(0, 160)}`, ms };
  }
  if (failed.length) return { cell, verdict: "fail", why: `${failed[0]!.step}: ${(failed[0]!.detail ?? "").slice(0, 200)}`, ms, reply };
  if (exit !== 0) return { cell, verdict: "fail", why: `journey exit ${exit}`, ms, reply };
  for (const name of cell.must ?? []) {
    const s = steps.find((x) => x.step === name);
    if (s?.status !== "pass") return { cell, verdict: "fail", why: `${name} did not run: ${(s?.detail ?? "not run").slice(0, 200)}`, ms, reply };
  }
  return { cell, verdict: "pass", why: "every step passed", ms, reply };
}

export function table(rows: Row[]): string {
  const head = `| Cell | Agent | Sign-in | Proof | Result | First reply | Turn 2 | Pause / resume | Turn after resume | Why |\n|---|---|---|---|---|---|---|---|---|---|`;
  const t = (n?: number) => (n === undefined ? "-" : n >= 10_000 ? `${(n / 1000).toFixed(0)} s` : `${(n / 1000).toFixed(1)} s`);
  const lines = rows.map((r) => {
    const pr = r.ms.pause !== undefined || r.ms.resume !== undefined ? `${t(r.ms.pause)} / ${t(r.ms.resume)}` : "-";
    const why = r.why.replace(/\|/g, "\\|").replace(/\n/g, " ");
    return `| ${r.cell.id} | ${r.cell.agent} | ${r.cell.signIn} | ${r.cell.proof} | ${r.verdict.toUpperCase()} | ${t(r.ms.reply)} | ${t(r.ms["turn 2 (same session)"])} | ${pr} | ${t(r.ms["turn after resume"])} | ${why} |`;
  });
  return [head, ...lines].join("\n");
}

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

export function main(argv: string[]): number {
  if (argv.includes("--list")) {
    for (const c of CELLS) console.log(`${c.id}\t${c.proof}\t${c.agent}\t${c.signIn}`);
    return 0;
  }
  const want = argValue("--cells", argv)?.split(",").filter(Boolean);
  const unknown = (want ?? []).filter((id) => !CELLS.some((c) => c.id === id));
  if (unknown.length) {
    console.error(`unknown cells: ${unknown.join(", ")} (--list names them)`);
    return 2;
  }
  // The bench is never part of a default run: it is long and makes many machines; name it in --cells.
  const cells = want ? CELLS.filter((c) => want.includes(c.id)) : CELLS.filter((c) => c.proof !== "bench");
  // The default is a folder mkdtemp makes, never a guessable /tmp name another account could make first.
  const given = argValue("--out", argv);
  const out = given ? path.resolve(given) : mkdtempSync(path.join(os.tmpdir(), "cloud-chat-matrix-"));
  mkdirSync(out, { recursive: true });
  // Everything but this script's own flags goes to every journey (--backend, --credentials, --team, --cmux).
  const own = new Set(["--cells", "--out"]);
  const pass: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (own.has(argv[i]!)) i++;
    else pass.push(argv[i]!);
  }
  const journey = fileURLToPath(new URL("./cloud-journey.ts", import.meta.url));
  const rows: Row[] = [];
  // A bench cell's own table (start-bench.md) follows the matrix, so the job summary carries it.
  const extra: string[] = [];
  for (const cell of cells) {
    const missing = cell.needs ? [cell.needs.env].flat().filter((name) => !process.env[name]) : [];
    if (cell.needs && missing.length) {
      rows.push({ cell, verdict: "skip", why: `no ${missing.join(", ")}: ${cell.needs.why}`, ms: {} });
      console.log(`SKIP ${cell.id}: no ${missing.join(", ")}`);
      continue;
    }
    const dir = path.join(out, cell.id);
    mkdirSync(dir, { recursive: true });
    // A cell that needs no login passes none, whatever this shell holds.
    const env = { ...process.env };
    if (!cell.needs) delete env.CODEX_AUTH_JSON;
    const t0 = Date.now();
    // `$NAME` in a cell's args is that environment value (a path that differs per host).
    const args = cell.args.map((a) => (a.startsWith("$") ? (process.env[a.slice(1)] ?? "") : a));
    const r = spawnSync("bun", [journey, ...pass, ...args, "--out", dir], { env, encoding: "utf8", maxBuffer: 64 << 20 });
    writeFileSync(path.join(dir, "stdout.txt"), `${r.stdout ?? ""}${r.stderr ?? ""}`);
    const file = path.join(dir, "journey.json");
    const steps: Step[] = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")).steps ?? []) : [];
    const row = judge(cell, steps, r.status ?? 1);
    rows.push(row);
    const bench = path.join(dir, "start-bench.md");
    if (existsSync(bench)) extra.push(readFileSync(bench, "utf8"));
    console.log(`${row.verdict.toUpperCase()} ${cell.id} ${((Date.now() - t0) / 1000).toFixed(0)} s :: ${row.why}`);
  }
  const md = `${table(rows)}\n${extra.map((e) => `\n${e}`).join("")}`;
  writeFileSync(path.join(out, "matrix.md"), md);
  console.log(`\n${md}\nmatrix: ${path.join(out, "matrix.md")}`);
  return rows.some((r) => r.verdict === "fail") ? 1 : 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
