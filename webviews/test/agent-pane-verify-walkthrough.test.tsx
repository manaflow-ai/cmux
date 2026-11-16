// l10n-allow-file: test fixture prompts, steps and agent answers, not shipped UI.
// A browser walkthrough an agent ran before it said a UI change was done (the REPL's
// `verifyFlow`, conversation/walkthrough.ts) draws under the turn's answer as a pass/fail strip of
// screenshots (Walkthrough.tsx).
import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { activity, assistant, summary, tool, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { NEXT_STEP, WALKTHROUGH, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { parseWalkthrough, toolWalkthrough } from "../src/agent-session/acpmux/conversation/walkthroughModel";
import { Walkthrough } from "../src/agent-session/acpmux/conversation/Walkthrough";

const shot = (n: number) => `[Image 1280x800 jpeg: /tmp/cmux-browser-host/1-x/walkthrough/r-${n}.jpg]`;
const report = (value: object) => JSON.stringify({ walkthrough: 1, url: "http://127.0.0.1:5173/", ...value });
const PASSED = report({
  passed: true,
  steps: [
    { n: 1, kind: "open", line: "Open Settings", ok: true, screenshot: shot(1) },
    { n: 2, kind: "click", line: "Click Save", ok: true, screenshot: shot(2) },
  ],
});
const FAILED = report({
  passed: false,
  steps: [
    { n: 1, kind: "open", line: "Open Settings", ok: true, screenshot: shot(1) },
    { n: 2, kind: "expect", line: 'See "Saved"', ok: false, error: "Timeout 5000ms exceeded", screenshot: shot(2) },
    { n: 3, kind: "click", line: "Reload", ok: false, skipped: true },
  ],
});
const NO_SERVER = report({
  passed: false,
  error: "No dev server answers at http://127.0.0.1:5173. Start it (bg_start) and run verifyFlow again.",
  steps: [{ n: 1, kind: "open", line: "Open /", ok: false, error: "No dev server answers" }],
});
/// What the REPL prints: readable lines, then the machine line.
const printed = (json: string) =>
  `PASS: 2 of 2 steps passed at http://127.0.0.1:5173/\nok 1. Open Settings\ncmux.walkthrough ${json}`;
const evalCall = (output: string, status = "completed") =>
  tool("mcp__cmux__browser_repl_eval", "other", status, {
    inputSummary: JSON.stringify({ code: "await verifyFlow(5173, [...])" }),
    output,
  });

const turn = (output: string, fields: { answer?: boolean; status?: string } = {}) =>
  [
    user("Make Save confirm", 6),
    activity([evalCall(output)], 5),
    ...(fields.answer === false ? [] : [assistant("Save confirms now; I clicked through it.", 5)]),
    summary(5, { status: fields.status ?? "completed" }),
  ] as AcpmuxRow[];

describe("toolWalkthrough", () => {
  test("reads the walkthrough line as the REPL printed it", () => {
    const found = toolWalkthrough(evalCall(printed(PASSED)).tool);
    expect(found?.passed).toBe(true);
    expect(found?.steps.map((s) => s.line)).toEqual(["Open Settings", "Click Save"]);
    expect(found?.steps[0]?.image).toBe("/tmp/cmux-browser-host/1-x/walkthrough/r-1.jpg");
  });

  test("reads it from inside an MCP result envelope", () => {
    const envelope = JSON.stringify({ content: [{ type: "text", text: printed(FAILED) }], isError: false });
    const found = toolWalkthrough(evalCall(envelope).tool);
    expect(found?.passed).toBe(false);
    expect(found?.steps.map((s) => [s.ok, s.skipped])).toEqual([
      [true, false],
      [false, false],
      [false, true],
    ]);
    expect(found?.steps[1]?.error).toBe("Timeout 5000ms exceeded");
  });

  test("a running call, other output and a broken line are no walkthrough", () => {
    expect(toolWalkthrough(evalCall(printed(PASSED), "in_progress").tool)).toBeUndefined();
    expect(toolWalkthrough(evalCall("all good").tool)).toBeUndefined();
    expect(toolWalkthrough(evalCall("cmux.walkthrough {nope").tool)).toBeUndefined();
    expect(parseWalkthrough(JSON.stringify({ walkthrough: 2, steps: [] }))).toBeUndefined();
  });

  // Review F2: `console.log(await cmux.browser_repl_eval(...))` in a cmux_exec script puts the
  // REPL's result in the answer's logs as a JSON string.
  test("reads it from a script's logs, where the REPL result is serialized JSON", () => {
    const repl = JSON.stringify({ content: [{ type: "text", text: printed(PASSED) }] });
    const answer = JSON.stringify({
      content: [{ type: "text", text: JSON.stringify({ logs: [repl], result: null }) }],
    });
    expect(toolWalkthrough(evalCall(answer).tool)?.steps.map((s) => s.line)).toEqual(["Open Settings", "Click Save"]);
  });

  // Review F1: any tool can print deeply nested JSON; reading it must neither throw nor recurse.
  // The app's web view overflows a recursive walk near 5,000 levels; Bun's larger stack near
  // 100,000, so the test goes that deep to fail on a recursive walk here too.
  test("deeply nested output is no walkthrough and does not throw", () => {
    const deep = `${"[".repeat(100_000)}"cmux.walkthrough "${"]".repeat(100_000)}`;
    expect(() => toolWalkthrough(evalCall(deep).tool)).not.toThrow();
    expect(toolWalkthrough(evalCall(deep).tool)).toBeUndefined();
    const rows = turn(deep);
    expect(() => turnView(rows, new Set())).not.toThrow();
  });

  // Review F1 at f808d71: a step's note may hold the mark; only a line that starts with it is read.
  test("a note that holds the mark does not hide the walkthrough", () => {
    const noted = report({ passed: true, steps: [{ n: 1, line: "Check cmux.walkthrough {x} prints", ok: true }] });
    expect(toolWalkthrough(evalCall(printed(noted)).tool)?.steps[0]?.line).toBe("Check cmux.walkthrough {x} prints");
  });

  test("a report that says passed over a failed step draws as failed", () => {
    const forged = report({ passed: true, steps: [{ n: 1, line: "Open", ok: false }] });
    expect(parseWalkthrough(forged)?.passed).toBe(false);
  });
});

describe("a walkthrough in the transcript", () => {
  test("draws right under the answer, and before a wrap-up's card", () => {
    const rows = turn(printed(PASSED));
    const wrap = tool("mcp__acpmux__wrap_up", "other", "completed", {
      inputSummary: JSON.stringify({ recap: "Save confirms now.", ask: "Open a PR?" }),
    });
    rows.splice(3, 0, activity([wrap], 5));
    const kinds = turnView(rows, new Set()).map((row) => row.kind);
    expect(kinds.indexOf(WALKTHROUGH)).toBe(kinds.indexOf("assistant") + 1);
    expect(kinds.indexOf(NEXT_STEP)).toBe(kinds.indexOf(WALKTHROUGH) + 1);
  });

  // Review F2 at f808d71: with no answer to hang under, the strip still draws before the card.
  test("a turn with no answer draws it before a wrap-up's card", () => {
    const rows = turn(printed(PASSED), { answer: false });
    const wrap = tool("mcp__acpmux__wrap_up", "other", "completed", {
      inputSummary: JSON.stringify({ recap: "Save confirms now.", ask: "Open a PR?" }),
    });
    rows.splice(2, 0, activity([wrap], 5));
    const kinds = turnView(rows, new Set()).map((row) => row.kind);
    expect(kinds.indexOf(WALKTHROUGH)).toBeGreaterThanOrEqual(0);
    expect(kinds.indexOf(NEXT_STEP)).toBe(kinds.indexOf(WALKTHROUGH) + 1);
  });

  test("draws once, the turn's last run, even when it ran twice", () => {
    const rows = turn(printed(FAILED));
    rows.splice(2, 0, activity([evalCall(printed(PASSED))], 5));
    const strips = turnView(rows, new Set()).filter((row) => row.kind === WALKTHROUGH);
    expect(strips).toHaveLength(1);
    expect(strips[0]?.walkthrough?.passed).toBe(true);
  });

  test("a turn with no answer still draws it, before its footer", () => {
    const kinds = turnView(turn(printed(PASSED), { answer: false }), new Set()).map((row) => row.kind);
    expect(kinds.indexOf(WALKTHROUGH)).toBeGreaterThanOrEqual(0);
    expect(kinds.indexOf("turnSummary")).toBeGreaterThan(kinds.indexOf(WALKTHROUGH));
  });

  test("a turn still running draws none yet", () => {
    const rows = turn(printed(PASSED)).filter((row) => row.kind !== "turnSummary");
    expect(turnView(rows, new Set(), { working: true }).some((row) => row.kind === WALKTHROUGH)).toBe(false);
  });
});

describe("the strip", () => {
  const html = (json: string) =>
    renderToStaticMarkup(createElement(Walkthrough, { id: "t", walkthrough: parseWalkthrough(json)! }));

  test("a passing flow says so, with one marked step per screenshot", () => {
    const out = html(PASSED);
    expect(out).toContain("is-pass");
    expect(out).toContain("2/2");
    expect(out.match(/cv-walk__step is-ok/g)).toHaveLength(2);
  });

  test("a failing expectation names its step, rings it red and skips the rest", () => {
    const out = html(FAILED);
    expect(out).toContain("is-fail");
    expect(out).toContain("1/3");
    expect(out).toContain("cv-walk__step is-failed");
    expect(out).toContain("cv-walk__step is-skipped");
    expect(out).toContain("Timeout 5000ms exceeded");
  });

  test("no dev server is a clear error, not a blank strip", () => {
    const out = html(NO_SERVER);
    expect(out).toContain("cv-walk__why");
    expect(out).toContain("No dev server answers at http://127.0.0.1:5173");
  });
});
