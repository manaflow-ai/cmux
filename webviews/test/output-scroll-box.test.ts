// Detector for the "Show all N lines" class (Leo, 2026-11-12: "this is a really useless show all 9
// lines. i think [another chat app] just lets you scroll, straight up?"). Every output and code card in the
// agent chat draws whole up to OUTPUT_BOX_LINES lines and scrolls inside a box that tall past them
// (conversation/outputScrollBox.css); none hides lines behind an expand button. This fails when a
// new "Show all N lines"-style string enters the pane's table, or a card brings back the old
// preview-and-button parts.
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";
import { OUTPUT_BOX_LINES, OUTPUT_SCROLL_BOX } from "../src/agent-session/acpmux/conversation/blockPartsModel";

const PANE = path.resolve(import.meta.dir, "../src/agent-session/acpmux");

type Unit = { stringUnit?: { value?: string }; variations?: { plural?: Record<string, Unit> } };
type Entry = { localizations?: { en?: Unit } };

const values = (unit: Unit | undefined): string[] => [
  ...(unit?.stringUnit?.value ? [unit.stringUnit.value] : []),
  ...Object.values(unit?.variations?.plural ?? {}).flatMap(values),
];

/// A label that hides an output's or a code block's lines behind a button: "Show all 9 lines",
/// "Show all output", "Show more lines", "Show all {n} files", "Show {n} more lines".
const HIDDEN_LINES =
  /^(show|view|see) (all|more|the rest of|full)( \{n\}| \d+)? (lines?|output|files?|rows?)\b|^(show|view) (\{n\}|\d+) more (lines?|rows?)\b/i;

test("the pane's table has no Show all N lines style label", () => {
  const table = JSON.parse(readFileSync(path.join(PANE, "Localizable.xcstrings"), "utf8")) as {
    strings: Record<string, Entry>;
  };
  const found = Object.entries(table.strings).flatMap(([key, entry]) =>
    values(entry.localizations?.en)
      .filter((value) => HIDDEN_LINES.test(value))
      .map((value) => `${key}: ${value}`),
  );
  expect(found).toEqual([]);
});

test("the detector's pattern catches the labels it is for", () => {
  for (const label of [
    "Show all 9 lines",
    "Show all {n} lines",
    "Show all output",
    "Show more lines",
    "Show all {n} files",
    "Show {n} more lines",
  ])
    expect([label, HIDDEN_LINES.test(label)]).toEqual([label, true]);
  for (const label of ["Show all chats", "Show more", "Show less", "Show in terminal", "Show all", "Show output"])
    expect([label, HIDDEN_LINES.test(label)]).toEqual([label, false]);
});

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) return sources(file);
    return /\.(tsx?|css)$/.test(name) && !/\.(test|gallery)\.tsx?$/.test(name) ? [file] : [];
  });
}

/// The parts the old preview was made of: the cut-and-button hook, its row, its CSS state, and the
/// keys its buttons read.
const OLD_PARTS =
  /\busePreview\(|\bPreviewMore\b|\bOutputMore\b|cv-output-more|data-preview="(cut|all)"|transcript\.showAllLines|fileCards\.showAllFiles|"shell\.showAll"|SHELL_COLLAPSED_LINES|PREVIEW_LINES/;

test("no output or code card in the pane cuts its lines to a preview with a button", () => {
  const found = sources(PANE).flatMap((file) =>
    readFileSync(file, "utf8")
      .split("\n")
      .flatMap((line, index) =>
        OLD_PARTS.test(line) ? [`${path.relative(PANE, file)}:${index + 1} ${line.trim()}`] : [],
      ),
  );
  expect(found).toEqual([]);
});

test("the box's line count is one number, in the code and in its CSS token", () => {
  const css = readFileSync(path.join(PANE, "conversation/outputScrollBox.css"), "utf8");
  expect(css).toContain(`--cv-output-box-lines: ${OUTPUT_BOX_LINES};`);
  expect(css).toContain(`.${OUTPUT_SCROLL_BOX} {`);
  // It never traps the transcript's wheel: at its edge the wheel chains on to the transcript.
  expect(css).toMatch(/\.cv-scroll-box \{[^}]*overscroll-behavior-y: auto;/);
  expect(css).not.toMatch(/overscroll-behavior(-y)?: contain/);
});

test("every output and code card draws its body in the shared scroll box", () => {
  for (const file of [
    "conversation/ShellBlock.tsx",
    "conversation/ToolOutputBody.tsx",
    "conversation/EditDiff.tsx",
    "conversation/FileResultCard.tsx",
    "shell/ShellRow.tsx",
    "backgroundTasks/BackgroundTaskCard.tsx",
  ])
    expect([file, readFileSync(path.join(PANE, file), "utf8").includes("OUTPUT_SCROLL_BOX")]).toEqual([file, true]);
});
