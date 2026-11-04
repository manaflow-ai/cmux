// Leo 2026-11-02, on the What's New sheet: "why is the what's new the 0 information density one".
// The day he looked at listed every change as one long run under the same arrow, with work-tracking
// codes ("P0 RESIZE KEYS K4: …", "(REOPEN-F7 part A2)", "P0 RESIZE F1 part 1 of 2"), "cmux …:"
// work-stream labels, a "Fixes and improvements" row, lines that repeat their title and
// infrastructure (ad hoc builds, failing runs). The page now lists a day's changes under their app
// area (#22838's area list), one clean line each, and folds a long area after its first rows.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/changelog/generated/strings.json";
import { mergedView } from "../src/pages/changelog/model";
import { plainLine, readableChange } from "../src/pages/changelog/readableChange";
import { AREA_ROWS, addedLine, sheetRows } from "../src/pages/changelog/SheetPage";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import { denseDay, longAreaDay } from "../src/pages/changelog/whatsNewFixtures";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.changelog/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function mount(notes: ReleaseNotes[], rows: number) {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => void mountChangelogPage(root, new MockChangelogProvider(notes) as never));
  for (let tries = 0; tries < 200 && root.querySelectorAll(".cls-row").length < rows; tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  return root;
}

test("work-tracking codes and cmux work-stream labels come off a line", () => {
  expect(plainLine("P0 RESIZE KEYS K4: Ctrl-Shift-J/K and Ctrl-Cmd-Down/Up move a row edge one exact step")).toBe(
    "Ctrl-Shift-J/K and Ctrl-Cmd-Down/Up move a row edge one exact step",
  );
  expect(plainLine("P0 RESIZE F1 part 1 of 2")).toBe("");
  expect(plainLine("Size and scale (REOPEN-F7 part A2).")).toBe("Size and scale.");
  expect(plainLine("Hidden terminals no longer wake the app (SWITCH FRAMES SF-5 B)")).toBe(
    "Hidden terminals no longer wake the app",
  );
  expect(plainLine("Cmux NEXT agent pane: a file drag rings the composer")).toBe("A file drag rings the composer");
  expect(plainLine("Cmux-tui + app: hidden terminals stay quiet")).toBe("Hidden terminals stay quiet");
  // Not codes: a key, a chip, an encoding, an acronym.
  for (const text of [
    "Press F1 for help",
    "M4 Pro Macs render faster",
    "UTF-8 paths open",
    "PR links open in the pane",
  ])
    expect(plainLine(text)).toBe(text);
});

test("infrastructure never reads as a change", () => {
  expect(readableChange("Start the Native link in ad hoc builds").internal).toBe(true);
  expect(readableChange("Cancelled, skipped and superseded runs are not counted as failing").internal).toBe(true);
});

test("a description that repeats its title shows only what it adds", () => {
  expect(addedLine("The host pressure warning is off by default", "Host pressure warning is off by default.")).toBe(
    undefined,
  );
  expect(
    addedLine(
      "The host pressure warning is off by default",
      "Host pressure warning is off by default; turn it on from the Command Palette.",
    ),
  ).toBe("Turn it on from the Command Palette.");
  expect(addedLine("Typing under load", "A read-only viewer no longer gets the typing person's priority.")).toBe(
    "A read-only viewer no longer gets the typing person's priority.",
  );
});

test("the day Leo saw: clean lines, no filler, no infrastructure, no codes", () => {
  const rows = sheetRows(mergedView(denseDay, "en"), createStrings(table));
  const text = rows.map((r) => [r.title, r.line ?? ""].join(" ").trim());
  const all = text.join("\n");
  expect(all).not.toMatch(/fixes and improvements/i);
  expect(all).not.toMatch(/\bP0\b|\bK4\b|REOPEN|SF-5|part \d+ of \d+|part A2|SWITCH FRAMES/);
  expect(all).not.toMatch(/^Cmux\b/m);
  expect(all).not.toMatch(/ad hoc builds|counted as failing/);
  const titles = rows.map((r) => r.title);
  // A title that was only codes takes its description's first sentence.
  expect(titles).toContain("Closing a pane no longer tears down its terminal during the close animation");
  expect(titles).toContain("Ctrl-Shift-J/K and Ctrl-Cmd-Down/Up move a row edge one exact step");
  expect(titles).toContain("A file drag rings the composer in the accent");
  const pressure = rows.find((r) => r.title === "Host pressure warning is off by default");
  expect(pressure?.line).toBe("Turn it on from the Command Palette");
  // No row's line repeats its title.
  for (const row of rows) if (row.line) expect(row.line.toLowerCase()).not.toContain(row.title.toLowerCase());
});

test("a day lists its changes under their app area, each with its glyph, name and count", async () => {
  const root = await mount(denseDay, 10);
  const areas = [...root.querySelectorAll(".cls-area")];
  expect(areas.length).toBeGreaterThan(2);
  for (const area of areas) {
    expect(area.querySelector(".cls-area-head .cls-icon svg path, .cls-area-head .cls-icon svg rect")).not.toBeNull();
    expect(area.querySelector(".cls-area-head .cl-count")?.textContent).toBe(
      String(area.querySelectorAll(".cls-row").length),
    );
  }
  const names = areas.map((a) => a.querySelector(".cls-area-name")?.textContent);
  expect(names).toContain("Terminal");
  expect(names).toContain("Cloud");
  // Other comes last.
  expect(names.indexOf("Other")).toBe(names.includes("Other") ? names.length - 1 : -1);
  expect(root.querySelector(".cls")?.textContent).not.toMatch(/Fixes and improvements|P0 RESIZE|REOPEN-F7/);
});

test("a long area shows its first rows and Show more, which opens the rest", async () => {
  const root = await mount(longAreaDay, AREA_ROWS);
  const sidebar = root.querySelector('.cls-area[data-area="sidebar"]')!;
  expect(sidebar.querySelector(".cl-count")?.textContent).toBe("12");
  expect(sidebar.querySelectorAll(".cls-row").length).toBe(AREA_ROWS);
  const more = sidebar.querySelector<HTMLButtonElement>(".cls-more")!;
  expect(more.textContent).toBe(`Show more${12 - AREA_ROWS}`);
  await act(async () => more.click());
  expect(sidebar.querySelectorAll(".cls-row").length).toBe(12);
  expect(sidebar.querySelector(".cls-more")).toBeNull();
  // A short area has no fold.
  expect(root.querySelector('.cls-area[data-area="terminal"] .cls-more')).toBeNull();
});

test("a digest line whose change the notes mark internal (tooling only) stays out", () => {
  const notes: ReleaseNotes = {
    ...denseDay[0]!,
    items: [{ title: "The last turn's Copy row shows at rest when it ended on work", pr: 1, internal: true }],
  };
  const titles = sheetRows(mergedView([notes], "en"), createStrings(table)).map((r) => r.title);
  expect(titles).not.toContain("The last turn's Copy row shows at rest when it ended on work");
  expect(titles).toContain("Star your favorite themes");
});
