#!/usr/bin/env bun
// Counterfactual workbench, first experiment (cmuxterm-hq#23810): fork a synthetic repo from an
// earlier agent turn, run an alternative instruction there, and compare both outcomes.
//
// Leo: "I particularly love the combination of runnable links, counterfactual workbenches and
// outcome budgets."
//
// What it models, against what exists on feat-cmux-next:
// - acpmux records per turn only `gitBranch` and `gitHead` on `turn_result` (hub/turn_git.rs);
//   `acp.session.fork {throughSeq | beforePromptId}` forks the conversation (hub/fork_at.rs), not
//   files. The session host's `git.checkpoint.create` (cmux-tui-core git_ops/checkpoint.rs) captures
//   the worktree as an immutable synthetic commit under `refs/cmux/checkpoints/<worktree>/<id>`
//   without touching HEAD, the index or the files, but nothing takes one per turn today.
// - So this script captures a checkpoint after each scripted turn the same way (temporary index:
//   tracked + untracked files, ignored and credential paths excluded, an untracked file over the
//   byte limit skipped and the checkpoint marked incomplete), forks a turn's checkpoint into an
//   isolated `git worktree` at the turn's original HEAD (provenance kept), with the transcript up to
//   that turn as the context capsule, a scrubbed environment and external actions off.
// - It compares that single action with what a person can do from today's record: a worktree at
//   the turn's `gitHead`, plus rebuilding uncommitted edits and context by hand.
//
// Per task: 3 scripted turns on the original lineage, a fork from turn 1, an alternative turn in the
// fork, a smoke test in both, then diff stat against the fork base, elapsed time and whether the
// alternative's patch applies to the base (clean) and to the original's current state (conflict
// check). One trap task makes turn 2 write a file outside the repo and POST to a local server: the
// fork reports both as not undone, and its own attempt is blocked. One refusal case forks from an
// incomplete checkpoint.
//
//   bun scripts/cmux-next/counterfactual-exp.ts [--out FILE] [--keep]

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

export const MAX_UNTRACKED_FILE_BYTES = 64 * 1024;
const CREDENTIAL = /(^|\/)(\.env(\..*)?|.*\.pem|id_rsa.*|credentials\.json)$/;

// ---------- git ----------

function git(cwd: string, args: string[], env: Record<string, string> = {}, input?: string): string {
  const out = spawnSync("git", args, {
    cwd,
    input,
    encoding: "utf8",
    env: { ...process.env, GIT_AUTHOR_NAME: "cf", GIT_AUTHOR_EMAIL: "cf@local", GIT_COMMITTER_NAME: "cf", GIT_COMMITTER_EMAIL: "cf@local", ...env },
  });
  if (out.status !== 0) throw new Error(`git ${args.join(" ")}: ${out.stderr}`);
  return out.stdout.trim();
}

function gitOk(cwd: string, args: string[]): { ok: boolean; stderr: string } {
  const out = spawnSync("git", args, { cwd, encoding: "utf8" });
  return { ok: out.status === 0, stderr: out.stderr.trim() };
}

// ---------- checkpoints (the git.checkpoint.create shape) ----------

export type Checkpoint = {
  id: string;
  ref: string;
  commit: string;
  tree: string;
  base: { head: string; branch: string | null };
  complete: boolean;
  skipped: { path: string; code: "too_large" }[];
  excluded: string[];
  included: { tracked: number; untracked: number };
};

/// The worktree as a tree object, built in a temporary index: HEAD, the user's index and the files
/// are only read.
function captureTree(dir: string, maxUntracked = MAX_UNTRACKED_FILE_BYTES) {
  const index = join(mkdtempSync(join(tmpdir(), "cf-idx-")), "index");
  const env = { GIT_INDEX_FILE: index };
  try {
    git(dir, ["read-tree", "HEAD"], env);
    const untracked = git(dir, ["ls-files", "-o", "--exclude-standard", "-z"]).split("\0").filter(Boolean);
    const ignored = git(dir, ["ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z"]).split("\0").filter(Boolean);
    const skipped: Checkpoint["skipped"] = [];
    const excluded = [...ignored];
    const add: string[] = [];
    for (const path of untracked) {
      if (CREDENTIAL.test(path)) excluded.push(path);
      else if (statSync(join(dir, path)).size > maxUntracked) skipped.push({ path, code: "too_large" });
      else add.push(path);
    }
    git(dir, ["add", "-u", "--", "."], env);
    if (add.length) git(dir, ["add", "--", ...add], env);
    const tree = git(dir, ["write-tree"], env);
    const tracked = git(dir, ["ls-files", "-z"]).split("\0").filter(Boolean).length;
    return { tree, skipped, excluded, included: { tracked, untracked: add.length } };
  } finally {
    rmSync(dirname(index), { recursive: true, force: true });
  }
}

export function createCheckpoint(dir: string, worktreeId: string, reason: string): Checkpoint {
  const head = git(dir, ["rev-parse", "HEAD"]);
  const branch = gitOk(dir, ["symbolic-ref", "-q", "--short", "HEAD"]).ok ? git(dir, ["symbolic-ref", "--short", "HEAD"]) : null;
  const captured = captureTree(dir);
  const id = `cp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const meta = JSON.stringify({ checkpoint_id: id, reason, base: { head, branch }, complete: captured.skipped.length === 0 });
  const commit = git(dir, ["commit-tree", captured.tree, "-p", head, "-F", "-"], {}, meta);
  const ref = `refs/cmux/checkpoints/${worktreeId}/${id}`;
  git(dir, ["update-ref", ref, commit]);
  return { id, ref, commit, tree: captured.tree, base: { head, branch }, complete: captured.skipped.length === 0, ...captured };
}

// ---------- scripted agent turns ----------

export type Effects = { outsideDir: string; serverUrl: string; external: "on" | "off" };
export type Turn = { instruction: string; files: Record<string, string | null>; commit?: boolean; effect?: boolean };
export type Task = { name: string; turns: [Turn, Turn, Turn]; alternative: Turn };

async function runTurn(dir: string, turn: Turn, fx: Effects): Promise<{ blocked: string[] }> {
  for (const [path, body] of Object.entries(turn.files)) {
    const file = join(dir, path);
    if (body === null) rmSync(file, { force: true });
    else {
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, body);
    }
  }
  const blocked: string[] = [];
  if (turn.effect) {
    // The external side effect: a file outside the repository and a network call.
    if (fx.external === "on") {
      writeFileSync(join(fx.outsideDir, "deployed.txt"), `deployed by: ${turn.instruction}\n`);
      await fetch(`${fx.serverUrl}/deploy`, { method: "POST", body: turn.instruction });
    } else {
      blocked.push("write outside repo", `POST ${fx.serverUrl}/deploy`);
    }
  }
  if (turn.commit) {
    git(dir, ["add", "-A", "--", ".", ":!.env"]);
    git(dir, ["commit", "-q", "-m", turn.instruction]);
  }
  return { blocked };
}

function smoke(dir: string): { pass: boolean; output: string } {
  if (!existsSync(join(dir, "smoke.js"))) return { pass: false, output: "no smoke.js" };
  const out = spawnSync(process.execPath, ["smoke.js"], { cwd: dir, encoding: "utf8", env: { PATH: process.env.PATH ?? "" } });
  return { pass: out.status === 0, output: (out.stdout + out.stderr).trim().split("\n").slice(-1)[0] ?? "" };
}

const smokeFor = (expr: string, expected: string) =>
  `const lib = require("./lib.js");\nconst got = JSON.stringify(${expr});\nif (got !== ${JSON.stringify(expected)}) { console.error("FAIL", got); process.exit(1); }\nconsole.log("ok", got);\n`;

const scaffold = (name: string, expr: string, expected: string, commit: boolean, extra: Record<string, string> = {}): Turn => ({
  instruction: `scaffold ${name} with a smoke test`,
  files: {
    "lib.js": `exports.${name} = () => { throw new Error("todo"); };\n`,
    "smoke.js": smokeFor(expr, expected),
    "NOTES.md": `turn 1 notes for ${name} (untracked)\n`,
    ".env": "API_TOKEN=secret-not-captured\n",
    ...extra,
  },
  commit,
});

/// Five paired tasks with divergent approaches; turn 1 is left uncommitted in three of them, as
/// an agent usually leaves it.
export function tasks(): Task[] {
  const t = (name: string, commit: boolean, expr: string, expected: string, a: string, a2: string, b: string, bWhy: string): Task => ({
    name,
    turns: [
      scaffold(name, expr, expected, commit),
      { instruction: `implement ${name}: approach A`, files: { "lib.js": a } },
      { instruction: `polish ${name}: document approach A`, files: { "lib.js": `// ${name}: approach A\n${a2}`, "NOTES.md": null, "CHANGELOG.md": `- ${name}\n` } },
    ],
    alternative: { instruction: `implement ${name}: ${bWhy}`, files: { "lib.js": b } },
  });
  return [
    t("sum", false, "lib.sum([1, 2, 3, 4])", "10",
      "exports.sum = (xs) => { let s = 0; for (const x of xs) s += x; return s; };\n",
      "exports.sum = (xs) => { let s = 0; for (const x of xs) s += x; return s; };\nexports.loop = true;\n",
      "exports.sum = (xs) => xs.reduce((a, b) => a + b, 0);\n", "approach B, reduce"),
    t("slugify", true, 'lib.slugify("  Hello, World!  ")', '"hello-world"',
      'exports.slugify = (s) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");\n',
      'exports.slugify = (s) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");\nexports.regex = true;\n',
      'exports.slugify = (s) => [...s.toLowerCase()].map((c) => (/[a-z0-9]/.test(c) ? c : "-")).join("");\n', "approach B, a char loop (keeps edge dashes)"),
    t("parseConfig", false, 'lib.parseConfig("a=1\\nb=two")', '{"a":"1","b":"two"}',
      'exports.parseConfig = (s) => Object.fromEntries(s.split("\\n").filter(Boolean).map((l) => l.split("=")));\n',
      'exports.parseConfig = (s) => Object.fromEntries(s.split("\\n").filter(Boolean).map((l) => l.split("=")));\nexports.lines = true;\n',
      'exports.parseConfig = (s) => { const o = {}; for (const m of s.matchAll(/^(\\w+)=(.*)$/gm)) o[m[1]] = m[2]; return o; };\n', "approach B, a regex scanner"),
    t("dedupe", true, "lib.dedupe([3, 1, 3, 2, 1])", "[3,1,2]",
      "exports.dedupe = (xs) => [...new Set(xs)];\n",
      "exports.dedupe = (xs) => [...new Set(xs)];\nexports.set = true;\n",
      "exports.dedupe = (xs) => xs.filter((x, i) => xs.indexOf(x) === i);\n", "approach B, filter + indexOf"),
    t("fizz", false, "lib.fizz(15)", '"1,2,Fizz,4,Buzz,Fizz,7,8,Fizz,Buzz,11,Fizz,13,14,FizzBuzz"',
      'exports.fizz = (n) => Array.from({ length: n }, (_, i) => { const k = i + 1; return (k % 3 ? "" : "Fizz") + (k % 5 ? "" : "Buzz") || String(k); }).join(",");\n',
      'exports.fizz = (n) => Array.from({ length: n }, (_, i) => { const k = i + 1; return (k % 3 ? "" : "Fizz") + (k % 5 ? "" : "Buzz") || String(k); }).join(",");\nexports.concat = true;\n',
      'exports.fizz = (n) => { const out = []; for (let k = 1; k <= n; k++) out.push(k % 15 === 0 ? "FizzBuzz" : k % 3 === 0 ? "Fizz" : k % 5 === 0 ? "Buzz" : String(k)); return out.join(","); };\n', "approach B, explicit branches"),
  ];
}

export function trapTask(): Task {
  const base = tasks()[0];
  return {
    name: "trap-deploy",
    turns: [
      base.turns[0],
      { ...base.turns[1], instruction: "implement sum and deploy it", effect: true },
      base.turns[2],
    ],
    alternative: { ...base.alternative, instruction: "implement sum with reduce and deploy it", effect: true },
  };
}

// ---------- fork ----------

export type Fork = {
  dir: string;
  lineage: { parentWorktree: string; turn: number; checkpoint: string; base: string };
  capsule: string[];
  exact: boolean;
  elapsedMs: number;
  actions: number;
};

export class ForkRefused extends Error {
  constructor(readonly reason: string, readonly detail: string) {
    super(`${reason}: ${detail}`);
  }
}

/// The single action: a worktree at the checkpoint's original HEAD, the checkpoint's files laid on
/// top (deleted paths removed, untracked files left untracked), and the transcript up to the turn.
export function forkFromCheckpoint(repo: string, cp: Checkpoint, turn: number, transcript: string[], into: string, opts: { approximate?: boolean } = {}): Fork {
  if (!cp.complete && !opts.approximate) {
    throw new ForkRefused("checkpoint_incomplete", `skipped ${cp.skipped.map((s) => `${s.path} (${s.code})`).join(", ")}; pass approximate to fork anyway`);
  }
  const started = performance.now();
  // No checkout: HEAD is the turn's base, the files are the checkpoint's tree (a path the turn
  // deleted is never written), and a mixed reset leaves the turn's untracked files untracked.
  git(repo, ["worktree", "add", "-q", "--no-checkout", "--detach", into, cp.base.head]);
  git(into, ["read-tree", "--reset", "-u", cp.tree]);
  git(into, ["reset", "-q"]);
  const elapsedMs = performance.now() - started;
  // Incomplete means files the turn had are not here, whatever the trees say.
  const exact = cp.complete && captureTree(into).tree === cp.tree;
  return { dir: into, lineage: { parentWorktree: repo, turn, checkpoint: cp.ref, base: cp.base.head }, capsule: transcript.slice(0, turn), exact, elapsedMs, actions: 1 };
}

/// Today's route: only the turn's `gitHead` is recorded, so a worktree there is all a person gets
/// without rebuilding; uncommitted edits of the turn are lost. Counts the manual actions it takes:
/// find the turn's head, add the worktree, re-create each file the turn left uncommitted, paste the
/// context into a new chat, start the agent there.
export function forkFromGitHead(repo: string, gitHead: string, cp: Checkpoint, into: string) {
  const started = performance.now();
  git(repo, ["worktree", "add", "-q", "--detach", into, gitHead]);
  const elapsedMs = performance.now() - started;
  const tree = captureTree(into).tree;
  const differing = tree === cp.tree ? [] : git(repo, ["diff", "--name-only", tree, cp.tree]).split("\n").filter(Boolean);
  return { dir: into, exact: differing.length === 0, missing: differing, elapsedMs, actions: 4 + differing.length };
}

// ---------- the experiment ----------

export type Side = { pass: boolean; output: string; diffStat: string; elapsedMs: number };
export type Row = {
  task: string;
  forkTurn: number;
  checkpointPerTurn: { turn: number; ref: string; gitHead: string; complete: boolean; included: Checkpoint["included"]; excluded: string[] }[];
  fork: { exact: boolean; elapsedMs: number; actions: number; capsuleTurns: number; isolated: boolean; lineage: Fork["lineage"] };
  manual: { exact: boolean; missing: string[]; actions: number };
  original: Side;
  alternative: Side;
  adopt: { ontoBase: boolean; ontoOriginal: boolean; conflict: string };
  external?: { effects: string[]; undone: boolean; stillPresent: boolean; serverHits: number; blockedInFork: string[]; hitsAfterFork: number };
};

function diffStat(dir: string, baseTree: string): string {
  return git(dir, ["diff", "--shortstat", baseTree, captureTree(dir).tree]) || "no change";
}

export async function runTask(root: string, task: Task, serverUrl: string, hits: () => number): Promise<Row> {
  const repo = join(root, task.name, "original");
  const outsideDir = join(root, task.name, "outside");
  mkdirSync(repo, { recursive: true });
  mkdirSync(outsideDir, { recursive: true });
  git(repo, ["init", "-q", "-b", "main"]);
  writeFileSync(join(repo, ".gitignore"), "node_modules/\n");
  writeFileSync(join(repo, "README.md"), `# ${task.name}\n`);
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "init"]);

  const fx: Effects = { outsideDir, serverUrl, external: "on" };
  const cps: Checkpoint[] = [];
  const heads: string[] = [];
  const transcript: string[] = [];
  let originalMs = 0;
  for (const [i, turn] of task.turns.entries()) {
    const t0 = performance.now();
    await runTurn(repo, turn, fx);
    if (i > 0) originalMs += performance.now() - t0;
    transcript.push(turn.instruction);
    heads.push(git(repo, ["rev-parse", "HEAD"]));
    cps.push(createCheckpoint(repo, "wt-original", `turn ${i + 1} ended`));
  }
  const forkTurn = 1;
  const cp = cps[forkTurn - 1];
  const originalBefore = captureTree(repo).tree;
  const effects = task.turns.slice(forkTurn).filter((t) => t.effect).map((t) => `${t.instruction}: wrote ${join(outsideDir, "deployed.txt")}, POST ${serverUrl}/deploy`);
  const hitsBefore = hits();

  const fork = forkFromCheckpoint(repo, cp, forkTurn, transcript, join(root, task.name, "fork"));
  const manual = forkFromGitHead(repo, heads[forkTurn - 1], cp, join(root, task.name, "manual"));

  const t0 = performance.now();
  const ran = await runTurn(fork.dir, task.alternative, { ...fx, external: "off" });
  const alternativeMs = performance.now() - t0;

  let s0 = performance.now();
  const orig = smoke(repo);
  originalMs += performance.now() - s0;
  s0 = performance.now();
  const alt = smoke(fork.dir);
  const altMs = alternativeMs + performance.now() - s0;
  const isolated = captureTree(repo).tree === originalBefore;

  const patch = git(fork.dir, ["diff", "--binary", cp.tree, captureTree(fork.dir).tree]) + "\n";
  const onto = (dir: string) => {
    const file = join(root, task.name, "alt.patch");
    writeFileSync(file, patch);
    return gitOk(dir, ["apply", "--check", file]);
  };
  const adoptBase = join(root, task.name, "adopt");
  forkFromCheckpoint(repo, cp, forkTurn, transcript, adoptBase);
  const ontoBase = onto(adoptBase);
  const ontoOriginal = onto(repo);

  const row: Row = {
    task: task.name,
    forkTurn,
    checkpointPerTurn: cps.map((c, i) => ({ turn: i + 1, ref: c.ref, gitHead: heads[i].slice(0, 12), complete: c.complete, included: c.included, excluded: c.excluded })),
    fork: { exact: fork.exact, elapsedMs: fork.elapsedMs, actions: fork.actions, capsuleTurns: fork.capsule.length, isolated, lineage: fork.lineage },
    manual: { exact: manual.exact, missing: manual.missing, actions: manual.actions },
    original: { ...orig, diffStat: diffStat(repo, cp.tree), elapsedMs: originalMs },
    alternative: { ...alt, diffStat: diffStat(fork.dir, cp.tree), elapsedMs: altMs },
    adopt: { ontoBase: ontoBase.ok, ontoOriginal: ontoOriginal.ok, conflict: ontoOriginal.ok ? "" : ontoOriginal.stderr.split("\n")[0] },
  };
  if (effects.length) {
    const file = join(outsideDir, "deployed.txt");
    row.external = {
      effects,
      undone: false,
      stillPresent: existsSync(file) && readFileSync(file, "utf8").includes("deploy"),
      serverHits: hitsBefore,
      blockedInFork: ran.blocked,
      hitsAfterFork: hits(),
    };
  }
  return row;
}

/// The refusal case: turn 1 leaves an untracked file over the byte limit, so its checkpoint is
/// incomplete and an exact fork is refused; `approximate` forks and says what is missing.
export function refusalCase(root: string) {
  const repo = join(root, "refusal", "original");
  mkdirSync(repo, { recursive: true });
  git(repo, ["init", "-q", "-b", "main"]);
  writeFileSync(join(repo, "README.md"), "# refusal\n");
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "init"]);
  writeFileSync(join(repo, "fixture.bin"), Buffer.alloc(MAX_UNTRACKED_FILE_BYTES + 1, 7));
  writeFileSync(join(repo, "lib.js"), "exports.x = 1;\n");
  const cp = createCheckpoint(repo, "wt-refusal", "turn 1 ended");
  let refused: string | null = null;
  try {
    forkFromCheckpoint(repo, cp, 1, ["add fixture"], join(root, "refusal", "fork"));
  } catch (error) {
    if (!(error instanceof ForkRefused)) throw error;
    refused = error.message;
  }
  const approx = forkFromCheckpoint(repo, cp, 1, ["add fixture"], join(root, "refusal", "approx"), { approximate: true });
  return { complete: cp.complete, refused, approximate: { exact: approx.exact, missing: cp.skipped.map((s) => s.path), hasLib: existsSync(join(approx.dir, "lib.js")) } };
}

export async function runExperiment(root: string) {
  let count = 0;
  const server = Bun.serve({ port: 0, fetch: () => { count += 1; return new Response("ok"); } });
  try {
    const url = `http://127.0.0.1:${server.port}`;
    const rows: Row[] = [];
    for (const task of tasks()) rows.push(await runTask(root, task, url, () => count));
    const trap = await runTask(root, trapTask(), url, () => count);
    return { rows, trap, refusal: refusalCase(root) };
  } finally {
    server.stop(true);
  }
}

const ms = (n: number) => `${n.toFixed(0)} ms`;

export function render(result: Awaited<ReturnType<typeof runExperiment>>): string {
  const lines: string[] = [];
  lines.push("| task | fork exact | gitHead-only exact | fork actions / manual | original (turns 2-3) | alternative (fork of turn 1) | adopt onto base / onto original |");
  lines.push("| --- | --- | --- | --- | --- | --- | --- |");
  for (const r of [...result.rows, result.trap]) {
    const side = (s: Side) => `${s.pass ? "pass" : "FAIL"}; ${s.diffStat}; ${ms(s.elapsedMs)}`;
    lines.push(`| ${r.task} | ${r.fork.exact} (${ms(r.fork.elapsedMs)}, isolated ${r.fork.isolated}) | ${r.manual.exact}${r.manual.missing.length ? ` (missing ${r.manual.missing.join(", ")})` : ""} | ${r.fork.actions} / ${r.manual.actions} | ${side(r.original)} | ${side(r.alternative)} | ${r.adopt.ontoBase ? "clean" : "conflict"} / ${r.adopt.ontoOriginal ? "clean" : "conflict"} |`);
  }
  const x = result.trap.external;
  if (x) {
    lines.push("", `trap: ${x.effects.join("; ")}`);
    lines.push(`  after fork from turn 1: undone=${x.undone}, outside file still present=${x.stillPresent}, server hits=${x.serverHits} -> ${x.hitsAfterFork} (fork blocked: ${x.blockedInFork.join(", ")})`);
  }
  const f = result.refusal;
  lines.push("", `refusal: checkpoint complete=${f.complete}; exact fork: ${f.refused ?? "not refused"}; approximate fork exact=${f.approximate.exact}, missing ${f.approximate.missing.join(", ")}`);
  return lines.join("\n");
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const out = args.includes("--out") ? args[args.indexOf("--out") + 1] : undefined;
  const root = mkdtempSync(join(tmpdir(), "cf-exp-"));
  const started = performance.now();
  const result = await runExperiment(root);
  console.log(render(result));
  console.log(`\ntotal ${ms(performance.now() - started)}; root ${root}`);
  if (out) writeFileSync(out, JSON.stringify(result, null, 2));
  if (!args.includes("--keep")) rmSync(root, { recursive: true, force: true });
}
