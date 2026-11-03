// l10n-allow-file: test fixture replies, not shipped UI.
// A turn's footer under its answer (TurnRows.tsx TurnFooter). Leo, 2026-10-21, on a footer reading
// "Worked for 0s · pin · now" that took a full line: "IF WE 0 SECONDS THEN IT DOESNT NEED TO TAKE
// UP SPACE". A turn under a second says no "Worked for", and a footer left with only its hover
// controls (Pin, Fork, its age) takes no line: the row is its turn gap alone.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { layoutConversation } from "../model";
import { translate, type Translate } from "../i18n";
import { footerLabel, isEmptyFooter, turnView } from "./turns";
import {
  MARK_FOOTER_ROW,
  MARK_STEP,
  TRANSCRIPT_FOOTER_CONTROL,
  TRANSCRIPT_FOOTER_GAP,
  rowMark,
  transcriptGap,
} from "../transcriptGrid";
import { TurnFooter } from "./TurnRows";

const t: Translate = (key, values) => translate(key, values, "en");

const footer = (fields: Partial<AcpmuxRow>): AcpmuxRow => ({
  id: "summary",
  version: 1,
  at: 1_000,
  kind: "turnSummary",
  status: "completed",
  ...fields,
});

test("a turn under a second says no Worked for", () => {
  for (const durationMs of [0, 1, 999]) {
    const row = footer({ durationMs });
    expect(footerLabel(t, row)).toBeUndefined();
    expect(renderToStaticMarkup(<TurnFooter row={row} />)).not.toContain("Worked for");
  }
});

test("a 5 s turn says Worked for 5s in its time's tooltip, never in front of the buttons", () => {
  // Leo, 2026-11-02: "this should not be placed in front of the copy/whatever buttons. those buttons
  // should always just be there left aligned".
  const row = footer({
    durationMs: 5_000,
    text: "Done.",
    tokens: { output: 359, input: 1_000, cacheRead: 327_800, cacheWrite: 0 },
  });
  expect(footerLabel(t, row)).toBe("Worked for 5s");
  const markup = renderToStaticMarkup(<TurnFooter row={row} />);
  expect(markup).not.toContain("cv-turn-summary");
  expect(markup).toMatch(/<span class="cv-message-footer-row cv-turn-footer-row"><span class="cv-turn-action-group">/);
  expect(markup).toMatch(/<time class="cv-turn-time"[^>]*title="Worked for 5s · ↓ 359 out ↑ 328.8K in"/);
});

// Leo, 2026-11-02, on "Worked for" drawn in front of Copy: "this should not be placed in front of
// the copy/whatever buttons. those buttons should always just be there left aligned".
test("the buttons lead the footer row; Worked for comes after them, in the time's tooltip", () => {
  const markup = renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 5_000, text: "Done." })} />);
  const group = markup.indexOf("cv-turn-action-group");
  expect(group).toBeGreaterThan(-1);
  expect(markup.indexOf("Copy")).toBeGreaterThan(group);
  expect(markup.indexOf('title="Worked for 5s"')).toBeGreaterThan(markup.indexOf("Copy"));
});

test("a turn stopped within a second still says it stopped", () => {
  expect(footerLabel(t, footer({ durationMs: 400, status: "cancelled" }))).toBe("You stopped after 0s");
});

test("a turn whose work folds under Worked for says nothing in its footer", () => {
  expect(footerLabel(t, footer({ durationMs: 5_000, folded: true }))).toBeUndefined();
});

test("a footer with only hover controls is empty; one with an answer or a failure is not", () => {
  expect(isEmptyFooter(footer({ durationMs: 0 }))).toBe(true);
  expect(isEmptyFooter(footer({ durationMs: 5_000, folded: true }))).toBe(true);
  expect(isEmptyFooter(footer({ durationMs: 0, text: "Done." }))).toBe(false);
  // Its Worked for is the time's tooltip now, so it no longer keeps the line.
  expect(isEmptyFooter(footer({ durationMs: 5_000 }))).toBe(true);
  expect(isEmptyFooter(footer({ durationMs: 0, status: "failed", error: "boom" }))).toBe(false);
  expect(renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 0 })} />)).toContain("cv-turn-actions--empty");
  expect(renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 0, text: "Done." })} />)).not.toContain(
    "cv-turn-actions--empty",
  );
});

const prompt = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "user", text: "Next" });

test("an empty footer adds no line; a footer with an answer is its 32 line of buttons", () => {
  // An empty footer's hover controls lie over the gap: no height, between two prompts or at the end.
  expect(layoutConversation([prompt("p"), footer({ durationMs: 0 }), prompt("q")], 720).heights[1]).toBe(0);
  expect(layoutConversation([prompt("p"), footer({ durationMs: 0 })], 720).heights[1]).toBe(0);
  // A footer with an answer to copy is a row of its own, ChatGPT's 32 buttons (design/transcript-spacing.md).
  expect(layoutConversation([prompt("p"), footer({ durationMs: 0, text: "Done." }), prompt("q")], 720).heights[1]).toBe(
    TRANSCRIPT_FOOTER_CONTROL,
  );
});

// Leo, 2026-11-02: "this spacing would be good + the latest copy buttons auto showing when the turn
// is done like chatgpt". The chat's last turn that spoke and then ended on a run of commands drew an
// empty footer: no buttons, a blank band where they go. Its row is a real 32 line now, 8 under the
// run, whose Copy copies the turn; an earlier such turn keeps its hover-only footer.
test("the chat's last turn that ended on work has a row of its own, 8 under the run", () => {
  const rows = [
    { id: "p", version: 1, at: 0, kind: "user", text: "Check what's installed" },
    { id: "a", version: 1, at: 1, kind: "assistant", text: "I'll check the installed apps." },
    {
      id: "w",
      version: 1,
      at: 2,
      kind: "activity",
      items: [
        { kind: "tool", text: "", tool: { toolCallId: "t1", title: "ls", kind: "execute", status: "completed" } },
      ],
    },
    { id: "s", version: 1, at: 3, kind: "turnSummary", status: "completed", durationMs: 5_000, toolCount: 1 },
  ] as AcpmuxRow[];
  const drawn = turnView(rows, new Set(), { agentFamily: "claude", now: 10_000 });
  const at = drawn.findIndex((row) => row.kind === "turnSummary");
  const last = drawn[at]!;
  expect(last.text).toBeUndefined();
  expect(last.turnCopy?.length).toBeGreaterThan(0);
  expect(isEmptyFooter(last)).toBe(false);
  expect(rowMark(last)).toBe(MARK_FOOTER_ROW);
  expect(renderToStaticMarkup(<TurnFooter row={last} />)).not.toContain("cv-turn-actions--empty");
  const layout = layoutConversation(drawn, 720);
  expect(layout.heights[at]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  const above = at - 1;
  expect(layout.tops[at]! - (layout.tops[above]! + layout.heights[above]!)).toBe(TRANSCRIPT_FOOTER_GAP);
  expect(transcriptGap(MARK_STEP, MARK_FOOTER_ROW)).toBe(TRANSCRIPT_FOOTER_GAP);
  // Once a prompt follows, that turn is no longer the last: its footer is hover-only again.
  const later = turnView(
    [...rows, { id: "q", version: 1, at: 4, kind: "user", text: "Next" } as AcpmuxRow],
    new Set(),
    {
      agentFamily: "claude",
      now: 10_000,
    },
  );
  expect(isEmptyFooter(later.find((row) => row.kind === "turnSummary")!)).toBe(true);
});

test("a work-only last turn that said nothing has nothing to copy and stays empty", () => {
  expect(isEmptyFooter(footer({ retryable: true }))).toBe(true);
  expect(isEmptyFooter(footer({ retryable: true, turnCopy: [{ text: "I'll check." }] }))).toBe(false);
  expect(isEmptyFooter(footer({ turnCopy: [{ text: "I'll check." }] }))).toBe(true);
});
