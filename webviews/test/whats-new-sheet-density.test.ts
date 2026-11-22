// Leo 2026-11-02: "WHY IS THE WHAT'S NEW THE 0 INFORMATION DENSITY ONE", on a What's New day whose
// rows read "Fixes and improvements / This build brings fixes and improvements.", "P0 RESIZE F1
// part 1 of 2", "Start the Native link in ad hoc builds / And name the check that refuses it", and
// "The host pressure warning is off by default / Host pressure warning is off by default; …", each
// with the same arrow. Every row now says what changed, once, in plain words.
import { expect, test } from "bun:test";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/changelog/generated/strings.json";
import { isFragment, mergedView, rowKind } from "../src/pages/changelog/model";
import { WORK_CODES, withoutWorkCodes } from "../src/pages/changelog/readableChange";
import { sheetRows } from "../src/pages/changelog/SheetPage";
import { lowDensityDay } from "../src/pages/changelog/whatsNewFixtures";

const rows = () => sheetRows(mergedView(lowDensityDay, "en"), createStrings(table));

test("no row is filler: no 'Fixes and improvements' row or line", () => {
  const all = rows();
  for (const row of all) {
    expect(row.title).not.toMatch(/fixes and improvements/i);
    expect(row.line ?? "").not.toMatch(/fixes and improvements/i);
  }
});

test("no row shows a work-stream code", () => {
  const codes = /\bP[0-3]\b|\b[A-Z]{2,}-[A-Z]?\d|\bSF-\d|\bpart \d+ of \d+|\bpart [A-Z]\d/;
  for (const row of rows()) expect([row.title, row.line].join(" ")).not.toMatch(codes);
});

test("no line is a piece of its title or repeats it", () => {
  for (const row of rows()) {
    if (!row.line) continue;
    expect([row.title, isFragment(row.line)]).toEqual([row.title, false]);
    const key = (text: string) =>
      text
        .toLowerCase()
        .replace(/^(?:the|a|an)\s+/u, "")
        .replace(/[.\s]+$/u, "");
    expect(key(row.line).startsWith(key(row.title))).toBe(false);
  }
});

test("the reported rows read as whole changes", () => {
  const titles = rows().map((r) => r.title);
  expect(titles).toContain("Star your favorite themes");
  // Ad hoc builds are build infrastructure (readableChange INTERNAL_WORDS): that row, joined or not, stays off.
  expect(titles.some((t) => /ad hoc builds/i.test(t))).toBe(false);
  expect(titles).toContain("Copy repos that borrow objects (alternates) to Cloud");
  expect(titles).toContain("Bound the Feed, its connect reads, Cloud chats and chat replay");
  expect(titles).toContain("Closing a pane no longer tears down its terminal during the close animation");
  expect(titles).toContain("Ctrl-Shift-J/K and Ctrl-Cmd-Down/Up move a row edge one exact step");
  const pressure = rows().find((r) => r.title === "Host pressure warning is off by default");
  expect(pressure?.line).toBe("Turn it on from the Command Palette");
  expect(titles).toContain("A file drag rings the composer in the accent, with the copy + (no dashed frame, no pill)");
  const hidden = rows().find((r) => r.title.startsWith("Hidden terminals' scroll events"));
  expect(hidden?.line).toBe(
    "Terminals that print while their workspace is hidden no longer wake cmux many times a second.",
  );
  // One row per change, the filler and infrastructure ones gone.
  expect(rows().length).toBe(12);
});

test("a line that says its title again becomes the title, never joined to it", () => {
  const notes = structuredClone(lowDensityDay.slice(0, 1));
  notes[0]!.whatsNew!.entries.push({
    id: "summary-99",
    category: "improved",
    title: { en: "When you close a pane" },
    summary: { en: "When you close a pane, its terminal keeps running until the animation ends." },
  } as never);
  const titles = sheetRows(mergedView(notes, "en"), createStrings(table)).map((r) => r.title);
  expect(titles.some((t) => /when you close a pane, when you close a pane/i.test(t))).toBe(false);
});

test("rows do not all carry the same icon", () => {
  const kinds = new Set(rows().map((r) => r.category));
  expect(kinds.size).toBeGreaterThanOrEqual(3);
  expect(rowKind("Closing a pane no longer tears down its terminal")).toBe("fixed");
  expect(rowKind("Add a star to themes")).toBe("new");
  expect(rowKind("Make built-in density toggles discoverable in Customize")).toBe("improved");
});

test("work-stream codes come off and leave the words", () => {
  expect(withoutWorkCodes("P0 RESIZE KEYS K4: Ctrl-Shift-J/K move a row edge")).toBe("Ctrl-Shift-J/K move a row edge");
  expect(withoutWorkCodes("P0 RESIZE F1 part 1 of 2")).toBe("");
  expect(withoutWorkCodes("Size and scale (REOPEN-F7 part A2)")).toBe("Size and scale");
  expect(withoutWorkCodes("hidden terminals stay quiet (SWITCH FRAMES SF-5 B)")).toBe("hidden terminals stay quiet");
  // Words that only look like codes stay.
  expect(withoutWorkCodes("Builds for the M4 Pro (M4 Pro) run faster")).toBe(
    "Builds for the M4 Pro (M4 Pro) run faster",
  );
  expect(withoutWorkCodes("H264 video plays (H264 only)")).toBe("H264 video plays (H264 only)");
  expect(withoutWorkCodes("Pick a model (GPT-5 only) per chat")).toBe("Pick a model (GPT-5 only) per chat");
});

test("a fragment is a piece of a sentence, a sentence is not", () => {
  for (const piece of [
    "And name the check that refuses it",
    "(alternates) to Cloud",
    "8 under the run",
    "Size and scale",
  ])
    expect([piece, isFragment(piece)]).toEqual([piece, true]);
  for (const whole of [
    "Not one globe.",
    "Transcribed on this Mac.",
    "macOS windows keep their shadow",
    "A pinned harness still takes a model.",
  ])
    expect([whole, isFragment(whole)]).toEqual([whole, false]);
});

// The pipeline strips the same codes from new notes (release-notes.py WORK_CODES): one pattern.
test("the page and the pipeline share one work-code pattern", () => {
  const script = `
import importlib.util, sys
spec = importlib.util.spec_from_file_location("notes", sys.argv[1])
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)
print(notes.WORK_CODES.pattern)
`;
  const run = Bun.spawnSync(["python3", "-c", script, `${import.meta.dir}/../../scripts/cmux-next/release-notes.py`]);
  expect(run.stderr.toString()).toBe("");
  expect(run.stdout.toString().trim()).toBe(WORK_CODES.source);
});
