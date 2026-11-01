// Leo 2026-11-01: "this is way too narrow and not info dense enough", on a What's New sheet that
// listed the same changes twice ("Cloud start replaces rejected Claude logins", "A pinned harness
// still takes a model", …) and split "Routing follow-ups (trim recovered route" from "Prepared
// presets only, cap before split).". A day of nightlies names its digest entries summary-0,
// summary-1, … in every build; the sheet keyed its rows by those ids, and as each build's notes
// loaded React kept stale rows and dropped others.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/changelog/generated/strings.json";
import { mergedView, titleKey } from "../src/pages/changelog/model";
import { sheetRows } from "../src/pages/changelog/SheetPage";
import { parseSheetLayout } from "../src/pages/changelog/store";
import { dayOfNightlies } from "../src/pages/changelog/whatsNewFixtures";

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

const expected = [
  "Show the Feed in Chief draws in Settings > Chief > Look",
  "Ultracode and Fast mode do not block Bring Back Local",
  "Drop saved incognito task ids whose tasks ended",
  "Routing follow-ups (trim recovered route, prepared presets only, cap before split)",
  "Cloud start replaces rejected Claude logins",
  "A message's More menu opens upward when it does not fit below",
  "Replace a Claude login the provider rejects",
  "A pinned harness still takes a model",
  "Each machine's projects carry its own colored computer",
  "An attached video's speech goes to the agent",
  "Copy again on the machine's new link after updating it",
  "Inbox rows share the tool rows' icon column",
  "A look at a video's frames draws as a filmstrip card",
  "A title or preview cut with an ellipsis never ends inside an emoji",
  "A key right after an arrow key sees the caret the arrow moved",
];

test("a day of nightlies gives every change one row with its own key, however many builds name summary-0", () => {
  const strings = createStrings(table);
  const view = mergedView(dayOfNightlies, "en");
  const rows = sheetRows(view, strings);
  expect(new Set(rows.map((r) => r.key)).size).toBe(rows.length);
  expect(new Set(rows.map((r) => titleKey(r.title))).size).toBe(rows.length);
  expect([...rows.map((r) => r.title)].sort()).toEqual([...expected].sort());
  // The first build keeps its own ids; a repeat takes its build.
  expect(rows.map((r) => r.key)).toContain("summary-0");
  expect(rows.map((r) => r.key)).toContain("summary-0@4134335440201");
});

test("a title cut inside its parentheses reads as the one line it was", () => {
  const rows = sheetRows(mergedView(dayOfNightlies.slice(0, 1), "en"), createStrings(table));
  const routing = rows.find((r) => r.title.startsWith("Routing follow-ups"));
  expect(routing).toEqual({
    key: "summary-3",
    category: "improved",
    title: "Routing follow-ups (trim recovered route, prepared presets only, cap before split)",
    line: undefined,
  });
});

test("titles compare without case, repeated spaces, curly quotes or a closing period", () => {
  expect(titleKey("A message’s  More menu.")).toBe(titleKey("a message's more menu"));
});

test("the sheet is inline by default; stack and grid stay reachable from the route", () => {
  expect(parseSheetLayout("")).toBe("inline");
  expect(parseSheetLayout("#/?sheet=stack")).toBe("stack");
  expect(parseSheetLayout("#/?sheet=grid&from=1&to=2")).toBe("grid");
  expect(parseSheetLayout("#/?sheet=roomy")).toBe("inline");
});

test("the page lists each change once while a day's builds load one by one", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => void mountChangelogPage(root, new MockChangelogProvider(dayOfNightlies) as never));
  for (let tries = 0; tries < 200 && root.querySelectorAll(".cls-row").length < expected.length; tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  expect(root.querySelector(".cls")?.classList.contains("cls-inline")).toBe(true);
  const titles = [...root.querySelectorAll(".cls-row-title")].map((t) => t.textContent ?? "");
  expect(titles.length).toBe(new Set(titles).size);
  expect([...titles].sort()).toEqual([...expected].sort());
});
