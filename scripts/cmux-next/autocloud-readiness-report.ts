/**
 * AutoCloud's readiness, as three pass/fail rows: mark, instant start, sync (autocloud-readiness.ts runs it).
 *
 * Leo, 2026-11-27: "you mark as autocloud, it starts instantly and works like dropbox to sync your thing first with
 * projectionfs then with the full or compressed amount fast through git carry/freestyle tunnel", and 22:57Z: "hey is
 * autocloud working? we need to get a sense of where we're all at and if it works and what we need to get it working."
 *
 * Pure: it folds one storage sync probe row (autocloud-sync-probe.ts, autocloud-sync-verdict.ts) into the three rows,
 * so the rules are tested without a Cloud. Each row is pass, fail or blocked:
 *
 *   mark           the owner's Auto machine is set and `move {to: cloud}` makes the store's holder vm:<machine>.
 *   instant start  the move is acknowledged within INSTANT_TOGGLE_MS and the chat's tree is on the machine within
 *                  the probe's 3 s bound (tree_visible), both from the toggle.
 *   sync           an edit crosses each way within 2 s, both trees hash the same, the chat comes home and the
 *                  laptop has the machine's edit.
 *
 * Blocked: the row's steps never ran because an earlier one (the setup, or an earlier row) failed; the row names it.
 * A row passes only on measured evidence; a missing step is never a pass.
 */
import { GATES_MS, STEPS, type Row, type StepName, type StepResult } from "./autocloud-sync-verdict.ts";

/** "Starts instantly": the move acknowledged (holder vm:<machine>) within this from the toggle. The tree's own bound is
 * the probe's (GATES_MS.tree_visible); the acknowledgement comes before the tree, so it gets the same bound. */
export const INSTANT_TOGGLE_MS = GATES_MS.tree_visible ?? 3000;

export type CheckName = "mark" | "instant_start" | "sync";
export type Check = {
  check: CheckName;
  status: "pass" | "fail" | "blocked";
  /** What it measured, in a sentence: the numbers on a pass, the failing step and its detail otherwise. */
  detail: string;
  /** The numbers behind it (ms), whatever was measured. */
  ms: Record<string, number>;
  /** The probe steps it reads, in order. */
  steps: StepName[];
};
export type Readiness = {
  outcome: "pass" | "fail";
  /** The first row that is not a pass, with why; absent on a pass. */
  error?: string;
  env: string;
  machine?: string;
  build?: string;
  checks: Check[];
  /** The setup the rows stand on (sign in, the machine, the laptop daemon, the chat): its first failure, if any. */
  setup: { status: "pass" | "fail"; detail: string; ms: Record<string, number> };
};

const SETUP: StepName[] = ["sign_in", "install", "machine", "vm_harness", "clock", "mac_daemon", "scratch_chat"];
const ROWS: Array<{ check: CheckName; steps: StepName[] }> = [
  { check: "mark", steps: ["auto_machine", "toggle_on"] },
  { check: "instant_start", steps: ["toggle_on", "tree_visible"] },
  { check: "sync", steps: ["mac_edit_to_vm", "vm_edit_to_mac", "both_match", "toggle_off", "mac_has_vm_edits"] },
];
const LABEL: Record<CheckName, string> = { mark: "Mark", instant_start: "Instant start", sync: "Sync" };

const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.round(v) : undefined);

/** The probe row's steps by name; a step the row lacks is a skip (never ran). */
function stepsOf(row: Partial<Row>): Map<StepName, StepResult> {
  const given = new Map((Array.isArray(row.steps) ? row.steps : []).map((s) => [s.step, s] as const));
  return new Map(STEPS.map((s) => [s, given.get(s) ?? { step: s, status: "skip" as const, ms: null, detail: "did not run" }]));
}

const why = (s: StepResult) => `${s.step}: ${s.detail || s.status}`.slice(0, 300);

/** One probe row (autocloud-sync-probe.ts --result) as the three readiness rows. */
export function readiness(row: Partial<Row>): Readiness {
  const by = stepsOf(row);
  const setupMs: Record<string, number> = {};
  const resume = num(row.resume_ms);
  if (resume !== undefined) setupMs.machine_resume_ms = resume;
  const setupBad = SETUP.map((s) => by.get(s)!).find((s) => s.status !== "pass");
  // A row with no steps at all is a driver failure before the probe ran (its error says why).
  const driverError = !Array.isArray(row.steps) || row.steps.length === 0 ? String(row.error ?? "the probe wrote no steps") : null;
  const setup = driverError
    ? { status: "fail" as const, detail: driverError.slice(0, 300), ms: setupMs }
    : setupBad
      ? { status: "fail" as const, detail: why(setupBad), ms: setupMs }
      : { status: "pass" as const, detail: `signed in, machine ${String(row.machine ?? "?")} ${String(row.machine_was ?? "ready")}, laptop daemon and chat up`, ms: setupMs };

  const checks: Check[] = [];
  let blockedBy: string | null = setup.status === "fail" ? `setup (${setup.detail})` : null;
  // A step an earlier row already reported failing (toggle_on is in mark and instant start) blocks the later row.
  const reported = new Set<StepName>();
  for (const { check, steps } of ROWS) {
    const ms: Record<string, number> = {};
    for (const s of steps) {
      const v = by.get(s)!.ms;
      if (v !== null && Number.isFinite(v) && (GATES_MS[s] !== undefined || s === "toggle_on" || s === "toggle_off")) ms[`${s}_ms`] = Math.round(v);
    }
    const results = steps.map((s) => by.get(s)!);
    const ran = results.filter((s) => s.status !== "skip");
    const failed = results.find((s) => s.status === "fail");
    let status: Check["status"];
    let detail: string;
    if (failed && reported.has(failed.step) && blockedBy) {
      status = "blocked";
      detail = `did not run: ${blockedBy}`;
    } else if (failed) {
      status = "fail";
      detail = why(failed);
    } else if (ran.length < results.length) {
      status = blockedBy ? "blocked" : "fail";
      const missing = results.find((s) => s.status === "skip")!;
      detail = blockedBy ? `did not run: ${blockedBy}` : `${missing.step} did not run`;
    } else {
      status = "pass";
      detail = "";
    }
    if (status === "pass" && check === "instant_start") {
      const t = ms.toggle_on_ms;
      if (t === undefined) { status = "fail"; detail = "toggle_on: no time measured"; }
      else if (t > INSTANT_TOGGLE_MS) { status = "fail"; detail = `toggle_on: ${t} ms, over the ${INSTANT_TOGGLE_MS} ms bound`; }
    }
    if (status === "pass") {
      detail = check === "mark"
        ? `Auto machine set; the store's holder became vm:${String(row.machine ?? "?")}`
        : check === "instant_start"
          ? `move acknowledged in ${ms.toggle_on_ms} ms, the tree on the machine in ${ms.tree_visible_ms} ms (bounds ${INSTANT_TOGGLE_MS}, ${GATES_MS.tree_visible} ms)`
          : `laptop to machine ${ms.mac_edit_to_vm_ms} ms, machine to laptop ${ms.vm_edit_to_mac_ms} ms (bound ${GATES_MS.mac_edit_to_vm} ms), trees match, home in ${ms.toggle_off_ms ?? "?"} ms with the machine's edit`;
    }
    checks.push({ check, status, detail, ms, steps });
    for (const s of steps) reported.add(s);
    if (status !== "pass" && !blockedBy) blockedBy = `${LABEL[check]} ${status === "fail" ? "failed" : "blocked"}`;
  }
  const first = checks.find((c) => c.status !== "pass");
  const out: Readiness = {
    outcome: first ? "fail" : "pass",
    env: String(row.env ?? "?"),
    checks,
    setup,
  };
  if (first) out.error = `${LABEL[first.check]}: ${first.detail}`.slice(0, 500);
  if (typeof row.machine === "string") out.machine = row.machine;
  if (typeof row.build === "string") out.build = row.build;
  return out;
}

const mark = (s: string) => (s === "pass" ? "PASS" : s === "fail" ? "FAIL" : "BLOCKED");

/** The report as plain text, one line a row: what the terminal and the job log show. */
export function text(r: Readiness): string {
  const lines = [`AutoCloud readiness (${r.env}${r.build ? `, ${r.build}` : ""}): ${mark(r.outcome)}`];
  lines.push(`  ${mark(r.setup.status).padEnd(8)} setup          ${r.setup.detail}${r.setup.ms.machine_resume_ms !== undefined ? ` (machine resume ${r.setup.ms.machine_resume_ms} ms)` : ""}`);
  for (const c of r.checks) lines.push(`  ${mark(c.status).padEnd(8)} ${LABEL[c.check].padEnd(14)} ${c.detail}`);
  return lines.join("\n") + "\n";
}

/** The report as a Markdown table: the job summary and the PR. */
export function markdown(r: Readiness): string {
  const cell = (s: string) => s.replace(/\|/g, "\\|").replace(/\n/g, " ");
  const rows = [
    `| setup | ${mark(r.setup.status)} | ${cell(r.setup.detail)}${r.setup.ms.machine_resume_ms !== undefined ? ` (machine resume ${r.setup.ms.machine_resume_ms} ms)` : ""} |`,
    ...r.checks.map((c) => `| ${LABEL[c.check]} | ${mark(c.status)} | ${cell(c.detail)} |`),
  ];
  return [
    `### AutoCloud readiness (${r.env}): ${mark(r.outcome)}`,
    "",
    r.build ? `Laptop daemon: \`${cell(r.build)}\`${r.machine ? `, machine \`${r.machine}\`` : ""}` : "",
    "",
    "| Check | Result | Evidence |",
    "| --- | --- | --- |",
    ...rows,
    "",
  ].join("\n");
}
