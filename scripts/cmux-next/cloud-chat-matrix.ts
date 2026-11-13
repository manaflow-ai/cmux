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

export type Cell = {
  id: string;
  agent: string;
  signIn: string;
  proof: "live" | "stubbed" | "expect";
  args: string[];
  /** Environment the cell needs; absent, the cell is skipped with this reason. */
  needs?: { env: string; why: string };
  /** For `expect` cells: the step that must fail, its error, and the most it may take. */
  expect?: { step: string; error: RegExp; withinMs: number };
};

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
  // No Cursor, Grok (SuperGrok, xAI key) or third-party provider-key cells: Leo has none of those accounts (Leo,
  // 2026-11-10: "I only have ChatGPT and Google ... Or else I ask the company to get me basic accounts later").
];

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
  const cells = want ? CELLS.filter((c) => want.includes(c.id)) : CELLS;
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
  for (const cell of cells) {
    if (cell.needs && !process.env[cell.needs.env]) {
      rows.push({ cell, verdict: "skip", why: `no ${cell.needs.env}: ${cell.needs.why}`, ms: {} });
      console.log(`SKIP ${cell.id}: no ${cell.needs.env}`);
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
    console.log(`${row.verdict.toUpperCase()} ${cell.id} ${((Date.now() - t0) / 1000).toFixed(0)} s :: ${row.why}`);
  }
  const md = `${table(rows)}\n`;
  writeFileSync(path.join(out, "matrix.md"), md);
  console.log(`\n${md}\nmatrix: ${path.join(out, "matrix.md")}`);
  return rows.some((r) => r.verdict === "fail") ? 1 : 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
