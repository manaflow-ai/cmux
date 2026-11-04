// l10n-allow-file: test fixture prompts and agent answers, not shipped UI.
// The agent's own wrap-up call (acpmux's `wrap_up` tool, conversation/wrapUp.ts) draws as the
// next-step box at the end of the turn: the recap, and the question with its answers when the turn
// leaves a decision; the call's own row goes. Leo, 2026-11-03, watching Claude Code Desktop: "yo
// wtf i want this kind of feature in cmux-next too".
import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { activity, assistant, summary, tool, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { NEXT_STEP, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { NextStepCard } from "../src/agent-session/acpmux/conversation/NextStepCard";
import { execWrapUp, isWrapUp, wrapUpAsk } from "../src/agent-session/acpmux/conversation/wrapUp";
import { recapFrom } from "../src/agent-session/acpmux/recap";

const RECAP = "The grid reserves a 4:5 box while images load, so it no longer shifts. All 14 tests pass.";
const call = (input: Record<string, unknown>, title = "mcp__acpmux__wrap_up", status = "completed") =>
  tool(title, "other", status, { inputSummary: JSON.stringify(input) });

const turn = (input: Record<string, unknown>, fields: { status?: string; title?: string; answer?: boolean } = {}) =>
  [
    user("Fix the layout shift on the product grid", 6),
    ...(fields.answer === false ? [] : [assistant("Done.", 5)]),
    activity([call(input, fields.title)], 5),
    summary(5, { status: fields.status ?? "completed" }),
  ] as AcpmuxRow[];

const nextSteps = (rows: readonly AcpmuxRow[]) => rows.filter((row) => row.kind === NEXT_STEP);
const hasWrapUpRow = (rows: readonly AcpmuxRow[]) =>
  rows.some((row) => row.kind === "activity" && row.items?.some((item) => isWrapUp(item.tool)));

describe("wrapUpAsk", () => {
  test("reads the recap, the question and its answers under every name a harness gives the tool", () => {
    const input = { recap: RECAP, ask: "Should I open a PR for this?", actions: ["Yes, open PR", "Not now"] };
    for (const title of ["mcp__acpmux__wrap_up", "mcp__cmux__acpmux_wrap_up"]) {
      const ask = wrapUpAsk(call(input, title).tool!);
      expect(ask?.recap).toBe(RECAP);
      expect(ask?.question).toBe("Should I open a PR for this?");
      expect(ask?.options.map((option) => option.label)).toEqual(["Yes, open PR", "Not now"]);
    }
    // Codex: `{server, tool, arguments}`.
    const codex = tool("acpmux.wrap_up", "other", "completed", {
      inputSummary: JSON.stringify({ server: "acpmux", tool: "wrap_up", arguments: input }),
    });
    expect(wrapUpAsk(codex.tool!)?.recap).toBe(RECAP);
  });

  test("a question with no answers gets Yes and Not now; no question gets no buttons", () => {
    expect(wrapUpAsk(call({ recap: RECAP, ask: "Fix the cart too?" }).tool!)?.options.map((o) => o.key)).toEqual([
      "recap.yes",
      "recap.notNow",
    ]);
    const alone = wrapUpAsk(call({ recap: RECAP }).tool!);
    expect(alone?.question).toBe("");
    expect(alone?.options).toEqual([]);
  });

  test("an empty or failed call, and other tools, are not a wrap-up", () => {
    expect(wrapUpAsk(call({}).tool!)).toBeUndefined();
    expect(wrapUpAsk(call({ recap: RECAP }, "mcp__acpmux__wrap_up", "failed").tool!)).toBeUndefined();
    expect(isWrapUp(tool("mcp__acpmux__send", "other", "completed", { inputSummary: "{}" }).tool)).toBe(false);
    expect(isWrapUp(tool("Bash", "execute", "completed", { command: "echo wrap_up" }).tool)).toBe(false);
  });
});

describe("a wrap-up in the transcript", () => {
  const input = { recap: RECAP, ask: "Should I open a PR for this?", actions: ["Yes, open PR", "Not now"] };

  test("draws the box under the answer, waiting, and drops the call's row", () => {
    const drawn = turnView(turn(input), new Set());
    const [card] = nextSteps(drawn);
    expect(card?.nextStep?.ask.recap).toBe(RECAP);
    expect(card?.nextStep?.answer).toBeUndefined();
    expect(hasWrapUpRow(drawn)).toBe(false);
    const kinds = drawn.map((row) => row.kind);
    expect(kinds.indexOf(NEXT_STEP)).toBe(kinds.indexOf("assistant") + 1);
    expect(drawn.find((row) => row.kind === "assistant")?.text).toBe("Done.");
  });

  test("a click's prompt folds it to the answer, the recap kept", () => {
    const drawn = turnView([...turn(input), user("Yes, open PR", 1)], new Set());
    expect(nextSteps(drawn)[0]?.nextStep).toMatchObject({ answer: "Yes, open PR", ask: { recap: RECAP } });
  });

  test("a recap alone draws in every turn, with no answer to wait for", () => {
    const drawn = turnView([...turn({ recap: RECAP }), user("thanks", 1)], new Set());
    expect(nextSteps(drawn)[0]?.nextStep?.ask.recap).toBe(RECAP);
    expect(nextSteps(drawn)[0]?.nextStep?.answer).toBeUndefined();
  });

  test("another agent's notice after it keeps the recap and drops the question", () => {
    const drawn = turnView(
      [...turn(input), user("Report from a helper", 1, { incoming: { kind: "notice", text: "Done" } })],
      new Set(),
    );
    expect(nextSteps(drawn)[0]?.nextStep?.ask).toMatchObject({ recap: RECAP, question: "" });
  });

  test("a turn with no answer text still gets the box, after its last row", () => {
    const drawn = turnView(turn(input, { answer: false }), new Set());
    const kinds = drawn.map((row) => row.kind);
    expect(kinds.indexOf(NEXT_STEP)).toBeGreaterThanOrEqual(0);
    expect(kinds.indexOf("turnSummary")).toBeGreaterThan(kinds.indexOf(NEXT_STEP));
  });

  test("a failed or still-running wrap-up call keeps its row", () => {
    for (const status of ["failed", "in_progress"]) {
      const rows = turn(input);
      const item = call(input, "mcp__acpmux__wrap_up", status);
      rows[2] = activity([item], 5);
      expect(JSON.stringify(turnView(rows, new Set()))).toContain(item.tool!.id);
    }
  });

  test("a code-mode wrap-up also sends the recap card aside", () => {
    const rows = turn(input);
    rows[1] = assistant("Done. Should I open a PR?", 5);
    rows[2] = activity(
      [
        tool("mcp__cmux__cmux_exec", "other", "completed", {
          inputSummary: JSON.stringify({ script: "await cmux.acpmux_wrap_up({...})" }),
          output: JSON.stringify({ calls: 1, call_log: [{ name: "acpmux_wrap_up", ok: true, shown: input }] }),
        }),
      ],
      5,
    );
    expect(recapFrom(rows)).toBeNull();
  });

  test("a stopped or failed turn draws no box", () => {
    for (const status of ["cancelled", "failed"])
      expect(nextSteps(turnView(turn(input, { status }), new Set()))).toHaveLength(0);
  });

  test("goes before a tagged ask in the prose, and the recap card steps aside", () => {
    const rows = turn(input);
    rows[1] = assistant("Done.\n\n[outward] Post the release notes?\n- Yes\n- No", 5);
    expect(nextSteps(turnView(rows, new Set()))[0]?.nextStep?.ask.question).toBe("Should I open a PR for this?");
    const asking = turn(input);
    asking[1] = assistant("Done. Should I open a PR?", 5);
    expect(recapFrom(asking)).toBeNull();
  });
});

describe("a wrap-up from a code-mode script", () => {
  // Default chats see only `cmux_exec`; the agent calls `cmux.acpmux_wrap_up(...)` from a script,
  // and code_mode.rs keeps what it showed in the call_log record as `shown`.
  const shown = input();
  const exec = (log: Record<string, unknown>[], script = "await cmux.acpmux_wrap_up({...})") =>
    tool("mcp__cmux__cmux_exec", "other", "completed", {
      inputSummary: JSON.stringify({ script }),
      output: JSON.stringify({ calls: log.length, call_log: log }),
    });
  const wrapped = { name: "acpmux_wrap_up", ok: true, shown };

  test("reads the card from the call_log and drops a script that only wrapped up", () => {
    const only = exec([wrapped]);
    expect(wrapUpAsk(only.tool!)?.recap).toBe(RECAP);
    expect(execWrapUp(only.tool)?.only).toBe(true);
    const drawn = turnView(
      [
        user("Fix it", 6),
        assistant("Done.", 5),
        activity([only], 5),
        summary(5, { status: "completed" }),
      ] as AcpmuxRow[],
      new Set(),
    );
    expect(nextSteps(drawn)[0]?.nextStep?.ask.question).toBe("Should I open a PR for this?");
    expect(JSON.stringify(drawn)).not.toContain(only.tool!.id);
  });

  test("a script that wrapped up and then failed keeps its row", () => {
    const failed = exec([wrapped]);
    failed.tool = { ...failed.tool!, status: "failed" };
    const drawn = turnView(
      [
        user("Fix it", 6),
        assistant("Done.", 5),
        activity([failed], 5),
        summary(5, { status: "completed" }),
      ] as AcpmuxRow[],
      new Set(),
    );
    expect(JSON.stringify(drawn)).toContain(failed.tool.id);
  });

  test("a script that did other work keeps its row and still draws the box", () => {
    const mixed = exec([{ name: "workspace_list", ok: true }, wrapped]);
    expect(execWrapUp(mixed.tool)?.only).toBe(false);
    const drawn = turnView(
      [
        user("Fix it", 6),
        assistant("Done.", 5),
        activity([mixed], 5),
        summary(5, { status: "completed" }),
      ] as AcpmuxRow[],
      new Set(),
    );
    expect(nextSteps(drawn)).toHaveLength(1);
    // A finished turn folds its work rows; the script is still in them.
    expect(JSON.stringify(drawn)).toContain(mixed.tool!.id);
  });

  test("a failed wrap-up call, or a script that never called it, is no box", () => {
    expect(execWrapUp(exec([{ name: "acpmux_wrap_up", ok: false }]).tool)).toBeUndefined();
    expect(
      execWrapUp(exec([{ name: "workspace_list", ok: true }], "await cmux.workspace_list()").tool),
    ).toBeUndefined();
  });
});

describe("NextStepCard with a recap", () => {
  test("waiting: the recap, the question and the answers", () => {
    const ask = wrapUpAsk(call(input()).tool!)!;
    const html = renderToStaticMarkup(
      createElement(NextStepCard, { ask, onAnswer: async () => undefined, registerKey: () => () => undefined }),
    );
    expect(html).toContain("acpmux-next-step__recap");
    expect(html.indexOf("acpmux-next-step__recap")).toBeLessThan(html.indexOf("acpmux-next-step__question"));
    expect(html.match(/acpmux-next-step__answer\b/g)).toHaveLength(2);
  });

  test("a recap alone: the box with its text and no buttons", () => {
    const ask = wrapUpAsk(call({ recap: RECAP }).tool!)!;
    const html = renderToStaticMarkup(createElement(NextStepCard, { ask, onAnswer: async () => undefined }));
    expect(html).toContain("acpmux-next-step--recap");
    expect(html).not.toContain("<button");
  });
});

function input() {
  return { recap: RECAP, ask: "Should I open a PR for this?", actions: ["Yes, open PR", "Not now"] };
}
