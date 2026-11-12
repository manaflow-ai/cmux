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
  MARK_WORKED,
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
  // The time's tooltip is its exact date and time, as a prompt's is; Worked for and the token rows
  // under it (turnTokensModel.ts `replyTimeDetail`).
  expect(markup).toMatch(/<time class="cv-turn-time"[^>]*title="[A-Z][a-z]{2} \d{1,2}, \d{4}, /);
  expect(markup).toMatch(
    /<time class="cv-turn-time"[^>]*data-tooltip-detail="Worked for 5s\nOutput 359\nInput 1K\u00a0uncached · 327.8K\u00a0cached"/,
  );
});

// Leo, 2026-11-02, on "Worked for" drawn in front of Copy: "this should not be placed in front of
// the copy/whatever buttons. those buttons should always just be there left aligned".
test("the buttons lead the footer row; Worked for comes after them, in the time's tooltip", () => {
  const markup = renderToStaticMarkup(<TurnFooter row={footer({ durationMs: 5_000, text: "Done." })} />);
  const group = markup.indexOf("cv-turn-action-group");
  expect(group).toBeGreaterThan(-1);
  expect(markup.indexOf("Copy")).toBeGreaterThan(group);
  expect(markup.indexOf('data-tooltip-detail="Worked for 5s"')).toBeGreaterThan(markup.indexOf("Copy"));
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
// empty footer. Its last words now draw under its "Worked for" (Leo, 2026-11-12: "in this case you
// didnt respond to me at all..."; turns.ts `answerAt`), and its footer, a real 32 line under them,
// copies them.
test("the chat's last turn that spoke and then ended on work draws its words over its footer", () => {
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
  expect(drawn.map((row) => row.kind)).toEqual(["user", "worked", "assistant", "turnSummary"]);
  const at = drawn.findIndex((row) => row.kind === "turnSummary");
  const last = drawn[at]!;
  expect(last.text).toBe("I'll check the installed apps.");
  expect(isEmptyFooter(last)).toBe(false);
  expect(rowMark(last)).toBe(MARK_FOOTER_ROW);
  expect(renderToStaticMarkup(<TurnFooter row={last} />)).not.toContain("cv-turn-actions--empty");
  const layout = layoutConversation(drawn, 720);
  expect(layout.heights[at]).toBe(TRANSCRIPT_FOOTER_CONTROL);
  expect(transcriptGap(MARK_WORKED, MARK_FOOTER_ROW)).toBe(0);
  expect(transcriptGap(MARK_STEP, MARK_FOOTER_ROW)).toBe(TRANSCRIPT_FOOTER_GAP);
});

test("the retry hint only marks a completed edit with a known non-empty patch", () => {
  const prompt = { id: "p", version: 1, at: 0, kind: "user", text: "Update the file" } as AcpmuxRow;
  const summary = { id: "s", version: 1, at: 3, kind: "turnSummary", status: "completed" } as AcpmuxRow;
  const edit = (
    status: string,
    oldText?: string,
    newText = "after",
    fragment?: true,
    canonical?: string,
    path = "/repo/file.ts",
  ): AcpmuxRow => ({
    id: `edit-${status}-${oldText ?? "unknown"}`,
    version: 1,
    at: 2,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "",
        tool: {
          id: "tool",
          title: "Edit file.ts",
          kind: "edit",
          status,
          diffs: [
            {
              path,
              ...(oldText === undefined ? {} : { oldText }),
              newText,
              ...(fragment && { fragment }),
              ...(canonical && { canonical }),
            },
          ],
        },
      },
    ],
  });
  const changed = turnView([prompt, edit("completed", "before"), summary], new Set(), { now: 10_000 }).find(
    (row) => row.kind === "turnSummary",
  );
  expect(changed?.changedFiles).toBe(true);

  for (const row of [
    turnView([prompt, edit("completed", "same", "same"), summary], new Set()).find(
      (item) => item.kind === "turnSummary",
    ),
    turnView([prompt, edit("failed", "before"), summary], new Set()).find((item) => item.kind === "turnSummary"),
    turnView([prompt, edit("pending", "before"), summary], new Set()).find((item) => item.kind === "turnSummary"),
    turnView([prompt, edit("completed", undefined, "new file"), summary], new Set()).find(
      (item) => item.kind === "turnSummary",
    ),
    turnView(
      [prompt, edit("completed", "before", "after"), edit("completed", "after", "before"), summary],
      new Set(),
    ).find((item) => item.kind === "turnSummary"),
    turnView(
      [prompt, edit("completed", "before", "after"), edit("completed", undefined, "before"), summary],
      new Set(),
    ).find((item) => item.kind === "turnSummary"),
    turnView(
      [prompt, edit("completed", undefined, "after"), edit("completed", "after", "before"), summary],
      new Set(),
    ).find((item) => item.kind === "turnSummary"),
    turnView(
      [prompt, edit("completed", "before", "after"), edit("completed", "after", "before", true), summary],
      new Set(),
    ).find((item) => item.kind === "turnSummary"),
    turnView(
      [
        prompt,
        edit("completed", "before", "after", undefined, undefined, "file.ts"),
        edit("completed", "after", "before", undefined, "/repo/file.ts", "file.ts"),
        summary,
      ],
      new Set(),
    ).find((item) => item.kind === "turnSummary"),
    turnView([prompt, edit("completed", undefined, "partial", true), summary], new Set()).find(
      (item) => item.kind === "turnSummary",
    ),
  ])
    expect(row?.changedFiles).toBeUndefined();
});

test("a work-only last turn that said nothing has nothing to copy and stays empty", () => {
  expect(isEmptyFooter(footer({ retryable: true }))).toBe(true);
  expect(isEmptyFooter(footer({ retryable: true, turnCopy: [{ text: "I'll check." }] }))).toBe(false);
  expect(isEmptyFooter(footer({ turnCopy: [{ text: "I'll check." }] }))).toBe(true);
});
