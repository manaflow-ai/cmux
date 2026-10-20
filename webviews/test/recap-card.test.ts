// l10n-allow-file: test fixture replies, not shipped UI.
// The recap card's reading of a finished turn (acpmux/recap.ts): a turn that completed and whose
// final answer ends by asking something gets a card; its yes names the action the question offers.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { plainText, recapAction, recapFrom } from "../src/agent-session/acpmux/recap";

let id = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: `${kind}-${(id += 1)}`,
  version: 1,
  at: id,
  kind,
  ...fields,
});
const turn = (answer: string, summary: Partial<AcpmuxRow> = {}): AcpmuxRow[] => [
  row("user", { text: "Fix the layout shift" }),
  row("activity", { items: [] }),
  row("assistant", { text: answer }),
  row("turnSummary", { id: "summary-42", seq: 42, status: "completed", ...summary }),
];

const PR_ANSWER =
  "Product images now have a width and height, and the grid reserves a 4:5 box while they load, so the product grid no longer shifts. All 14 tests pass, including the new layout shift test.\n\nShould I open a PR for this?";

describe("recapFrom", () => {
  test("a completed turn that asks to open a PR offers Yes, open PR", () => {
    expect(recapFrom(turn(PR_ANSWER))).toEqual({
      key: "summary-42",
      summary:
        "Product images now have a width and height, and the grid reserves a 4:5 box while they load, so the product grid no longer shifts. All 14 tests pass, including the new layout shift test.",
      question: "Should I open a PR for this?",
      action: "open PR",
      reply: "Yes, open PR",
    });
  });

  test("a question on the summary's own line is split off it", () => {
    const recap = recapFrom(turn("Fixed the flaky test. Want me to run the tests?"));
    expect(recap).toMatchObject({ summary: "Fixed the flaky test.", question: "Want me to run the tests?" });
    expect(recap?.reply).toBe("Yes, run tests");
  });

  test("any other question is a plain Yes", () => {
    const recap = recapFrom(turn("The cache is warm. Does the new layout look right to you?"));
    expect(recap).toMatchObject({ question: "Does the new layout look right to you?", reply: "Yes" });
    expect(recap?.action).toBeUndefined();
  });

  test("no question, or a question before the end, shows nothing", () => {
    expect(recapFrom(turn("All 14 tests pass."))).toBeNull();
    expect(recapFrom(turn("Should I open a PR? I went ahead and opened #128."))).toBeNull();
  });

  test("a failed or cancelled turn shows nothing", () => {
    expect(recapFrom(turn(PR_ANSWER, { status: "error", error: "rate limited" }))).toBeNull();
    expect(recapFrom(turn(PR_ANSWER, { status: "cancelled" }))).toBeNull();
  });

  test("a running turn, a new prompt or a waiting ask shows nothing", () => {
    expect(recapFrom(turn(PR_ANSWER), { working: true })).toBeNull();
    expect(recapFrom(turn(PR_ANSWER), { asking: true })).toBeNull();
    expect(recapFrom([...turn(PR_ANSWER), row("user", { text: "yes" })])).toBeNull();
    expect(
      recapFrom([row("user", { text: "go" }), row("assistant", { text: "Should I?", streaming: true })]),
    ).toBeNull();
  });

  test("the answer reads as plain text: fences, list markers, emphasis and links dropped", () => {
    const recap = recapFrom(
      turn(
        [
          "## Done",
          "",
          "- Gave **product images** a `width` and _height_",
          "- See [the grid](https://example.com/grid)",
          "",
          "```ts",
          "const box = 4 / 5; // what now?",
          "```",
          "",
          "**Should I open a PR for this?**",
        ].join("\n"),
      ),
    );
    expect(recap).toMatchObject({
      summary: "Gave product images a width and height See the grid",
      question: "Should I open a PR for this?",
      reply: "Yes, open PR",
    });
  });
});

describe("recapAction", () => {
  test("drops articles and trailing filler, keeps acronyms", () => {
    expect(recapAction("Should I open a PR for this?")).toBe("open PR");
    expect(recapAction("Would you like me to Merge the branch now?")).toBe("merge branch");
    expect(recapAction("Do you want me to push it too?")).toBe("push it");
  });

  test("a long phrase or a choice falls back to Yes", () => {
    expect(recapAction("Should I update the changelog and the docs for the new flag?")).toBeUndefined();
    expect(recapAction("Shall I commit or wait?")).toBeUndefined();
    expect(recapAction("Is this right?")).toBeUndefined();
  });
});

test("plainText keeps the words of inline marks", () => {
  expect(plainText("1. Use *this* and ~~that~~ in snake_case_names")).toBe("Use this and that in snake_case_names");
});
