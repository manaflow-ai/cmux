// Grading for tool evals. A sample is graded on two things:
// - state: the session before and after, with the agent-evals checks
//   (tests/agent-evals/grade.mjs: placement, focus, grouping, ...);
// - calls: what the agent called, as t3code's mcp-tool-use eval grades it.
// Pure functions; grade.test.mjs covers them.
import { CHECKS, CHECK_CATEGORY } from "../agent-evals/grade.mjs";

/**
 * One cmux operation the agent ran, however it reached cmux:
 *   { via: "exec" | "mcp" | "cli", tool, ok, input?, script? }
 * `tool` is the MCP tool name (`pane_split`); a CLI call's tool is its first
 * two words joined (`pane_split` for `cmux pane split`), ids skipped.
 */
export function cliTool(argv) {
  const SELECTORS = new Set(["current", "focused", "caller", "right", "left", "page"]);
  const words = argv.filter((a) => !a.startsWith("-") && !/^(ws|pane|tab|term|screen|win|tg|wg|browser)_[0-9a-f]/.test(a) && !a.includes(":") && !SELECTORS.has(a));
  return words.slice(0, 2).join("_");
}

const BOUND = /^([<>]=)(-?\d+(?:\.\d+)?)$/;
/** `args` match partially: `~text` is a case-insensitive substring, "<=N" / ">=N" bound a number. */
export function matches(expected, actual) {
  if (typeof expected === "string") {
    if (expected.startsWith("~")) return typeof actual === "string" && actual.toLowerCase().includes(expected.slice(1).toLowerCase());
    const bound = BOUND.exec(expected);
    if (bound && typeof actual === "number") return bound[1] === "<=" ? actual <= Number(bound[2]) : actual >= Number(bound[2]);
  }
  if (expected && typeof expected === "object" && !Array.isArray(expected)) {
    if (!actual || typeof actual !== "object") return false;
    return Object.entries(expected).every(([k, v]) => matches(v, k.split(".").reduce((o, p) => o?.[p], actual)));
  }
  return JSON.stringify(expected) === JSON.stringify(actual);
}

const callMatches = (spec, call) => {
  const tools = Array.isArray(spec.tool) ? spec.tool : [spec.tool];
  const named = (t) =>
    t.startsWith("*") && t.endsWith("*") ? call.tool.includes(t.slice(1, -1)) : t.endsWith("*") ? call.tool.startsWith(t.slice(0, -1)) : call.tool === t;
  if (!tools.some(named)) return false;
  if (spec.ok !== undefined && call.ok !== spec.ok) return false;
  return !spec.args || (call.input !== undefined && matches(spec.args, call.input));
};

/** Checks on calls, the agent's text and its scripts. Each returns { name, ok, detail, category }. */
export function gradeCalls(expect, run) {
  const out = [];
  const add = (name, ok, detail, category) => out.push({ name, ok: !!ok, detail, category, required: true, weight: 1 });
  const ops = run.ops;
  for (const spec of expect.calls ?? []) {
    add(`calls ${JSON.stringify(spec)}`, ops.some((c) => callMatches(spec, c)), "", "not_done");
  }
  for (const spec of expect.callsMustNot ?? []) {
    const bad = ops.filter((c) => callMatches(spec, c));
    add(`callsMustNot ${JSON.stringify(spec)}`, bad.length === 0, bad.map((c) => c.tool).join(", "), "wrong_tool");
  }
  for (const [tool, n] of Object.entries(expect.maxCalls ?? {})) {
    const count = tool === "*" ? ops.length : ops.filter((c) => c.tool === tool).length;
    add(`maxCalls ${tool}<=${n}`, count <= n, `${count}`, "wasted_calls");
  }
  if (expect.maxErrors !== undefined) {
    const errors = ops.filter((c) => !c.ok);
    add(`maxErrors<=${expect.maxErrors}`, errors.length <= expect.maxErrors, errors.map((c) => `${c.tool}: ${c.error ?? ""}`.slice(0, 120)).join(" | "), "tool_errors");
  }
  if (expect.maxSteps !== undefined) add(`maxSteps<=${expect.maxSteps}`, run.steps <= expect.maxSteps, `${run.steps}`, "wasted_calls");
  if (expect.order) {
    const firsts = expect.order.map((t) => ops.findIndex((c) => c.tool === t));
    const ok = firsts.every((i) => i >= 0) && firsts.every((i, k) => k === 0 || firsts[k - 1] < i);
    add(`order ${expect.order.join(" < ")}`, ok, firsts.join(","), "wrong_order");
  }
  for (const re of expect.shellMustNot ?? []) {
    const bad = run.shell.filter((cmd) => new RegExp(re).test(cmd));
    add(`shellMustNot /${re}/`, bad.length === 0, bad.slice(0, 2).join(" | ").slice(0, 200), "wrong_tool");
  }
  for (const re of expect.textMust ?? []) add(`textMust /${re}/`, new RegExp(re).test(run.text), "", "wrong_answer");
  for (const re of expect.textMustNot ?? []) add(`textMustNot /${re}/`, !new RegExp(re).test(run.text), (run.text.match(new RegExp(re)) ?? [""])[0], "wrong_answer");
  return out;
}

const lower = (s) => String(s ?? "").toLowerCase();
const newWorkspaces = (ctx) => ctx.after.workspaces.filter((w) => !ctx.before.workspaces.some((b) => b.id === w.id));

/** State checks of tool evals, over the same context as agent-evals' checks. */
export const LOCAL_CHECKS = {
  /** One new workspace whose name has one of `words` and is not a default or the prompt. */
  new_workspace_named(ctx, { words, maxWords = 6 }) {
    const extra = newWorkspaces(ctx);
    const ok = extra.length === 1 && words.some((w) => lower(extra[0].name).includes(lower(w))) && extra[0].name.trim().split(/\s+/).length <= maxWords;
    return { ok, detail: extra.map((w) => w.name).join(", ") || "none", category: extra.length ? "bad_name" : "not_done" };
  },
  workspace_named(ctx, { workspace, name }) {
    const id = workspace === "origin" ? ctx.origin.workspace_id : workspace;
    const w = ctx.after.workspaces.find((x) => x.id === id);
    return { ok: lower(w?.name).trim() === lower(name), detail: w?.name ?? "missing", category: "not_done" };
  },
  tab_absent(ctx, { label }) {
    const left = ctx.after.tabs.filter((t) => lower(t.label) === lower(label));
    return { ok: left.length === 0, detail: `${left.length} left`, category: "not_done" };
  },
  tab_present(ctx, { label }) {
    const found = ctx.after.tabs.some((t) => lower(t.label) === lower(label));
    return { ok: found, detail: ctx.after.tabs.map((t) => t.label).join(", "), category: "closed_user_tab" };
  },
  workspace_first(ctx, { name }) {
    const sorted = [...ctx.after.workspaces].sort((a, b) => (a.sidebar_index ?? a.index ?? 0) - (b.sidebar_index ?? b.index ?? 0));
    return { ok: lower(sorted[0]?.name) === lower(name), detail: sorted.map((w) => w.name).join(", "), category: "not_done" };
  },
};

/** State checks from agent-evals, by name; `ctx` is the agent-evals grading context. */
export function gradeState(specs, ctx) {
  return (specs ?? []).map((spec) => {
    const required = spec.required !== false;
    try {
      const fn = LOCAL_CHECKS[spec.check] ?? CHECKS[spec.check];
      if (!fn) throw new Error(`unknown check ${spec.check}`);
      const r = fn(ctx, spec.params ?? {});
      return { name: spec.check, ok: r.ok, detail: r.detail ?? "", category: r.category ?? CHECK_CATEGORY[spec.check], required, weight: 1 };
    } catch (e) {
      return { name: spec.check, ok: false, detail: String(e.message ?? e), category: "harness_error", required, weight: 1 };
    }
  });
}

export function verdict(checks) {
  const failed = checks.find((c) => c.required && !c.ok);
  return { pass: !failed, ...(failed ? { category: failed.category, failed: failed.name } : {}) };
}

/** A case fails when half or more of its samples fail. */
export function caseVerdict(samples) {
  const fails = samples.filter((s) => !s.pass).length;
  return { pass: fails * 2 < samples.length, fails, samples: samples.length };
}
