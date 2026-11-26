// l10n-allow-file: test fixtures.
// u51892 (2026-11-23, on the sidebar's Updated card reading `Settings: fix "the glass on it`): "the stuff in
// this message box is now just cut off ... we need to show everything". The card's change line was the
// change's first clause (updateSummary.ts shortTitle, at most 48 characters, cut at a comma even inside a
// quote). The card now shows the change in full and wraps it; the clause stays only to pick the rows.
import { expect, test } from "bun:test";
import { summarizeHighlights } from "../src/pages/changelog/updateSummary";

const item = (title: string) => ({ id: "a", title, summary: null, category: "fixed" as const });

test("a change longer than one clause reads in full, cased as its phrase", () => {
  // Areas come from the words (areas.ts), not a "Settings:" prefix.
  const title = "Fix the glass on the settings panels, so toggles read on bright wallpapers";
  const summary = summarizeHighlights({ items: [item(title)], moreCount: 0, language: "en" } as never);
  const row = summary.rows[0]!;
  expect(row.phrases[0]!.length).toBeLessThan(row.full[0]!.length);
  expect(row.phrases).toEqual(["fix the glass on the settings panels"]);
  expect(row.full).toEqual(["fix the glass on the settings panels, so toggles read on bright wallpapers"]);
  expect(row.full[0]!.charAt(0)).toBe(row.phrases[0]!.charAt(0));
});

test("a short change is the same in full as its phrase", () => {
  const summary = summarizeHighlights({
    items: [item("Groups in the sidebar take a palette color")],
    moreCount: 0,
    language: "en",
  } as never);
  const row = summary.rows[0]!;
  expect(row.full).toEqual(row.phrases);
});
