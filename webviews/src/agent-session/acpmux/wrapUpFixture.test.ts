// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The "wrap-up" debug seed draws the Needs your input card while its turn runs (Leo, 2026-11-19,
// on the Needs your input cards: "odd looking / plus it's not instant yet"), so the NIGHTLY capture
// agent-needs-input-live.json shows it: the seeded rows through the pane's own turnView.
import { describe, expect, test } from "bun:test";
import { NEXT_STEP, turnView } from "./conversation/turns";
import { WRAP_UP_SNAPSHOT, wrapUpRows } from "./wrapUpFixture";

describe("the wrap-up debug seed", () => {
  test("is a running turn", () => {
    expect(WRAP_UP_SNAPSHOT.isWorking).toBe(true);
  });

  test("draws the Needs your input card in place of its call while the turn runs", () => {
    const shown = turnView(wrapUpRows(0), new Set(), { working: WRAP_UP_SNAPSHOT.isWorking });
    const cards = shown.filter((row) => row.kind === NEXT_STEP);
    expect(cards).toHaveLength(1);
    const ask = cards[0]!.nextStep!.ask;
    expect(ask.recap).toContain("Fixed the flaky retry test");
    expect(ask.question).toBe("Open the PR and merge it once CI is green?");
    expect(ask.options.map((option) => option.label)).toEqual(["Open and merge", "Open as draft", "Not now"]);
    expect(shown.some((row) => row.items?.some((item) => item.tool?.id === "wrap-up-call-tool"))).toBe(false);
  });
});
