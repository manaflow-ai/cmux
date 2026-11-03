// Lawrence 2026-10-31 (msg 19251): "what's new page looks bad, make many variations for me to pick
// from". The default picked from the gallery (cmux-shots/whatsnew-variations): an Apple-style
// What's New sheet. Each change is one row: an icon for its kind, a bold one-line title and at most
// one muted line under it; release days newest first, each under its date. No version tags, build
// numbers, pull request chips or category headings: those stay in the Ledger (`design=ledger`).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { ReleaseNotes } from "../src/pages/changelog/types";

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

const entry = (id: string, category: "new" | "improved" | "fixed", title: string, summary: string) => ({
  id,
  category,
  title: { en: title },
  summary: { en: summary },
});

const notes: ReleaseNotes[] = [
  {
    build: "4124615690001",
    shortVersion: "1.0.0-nightly.4124615690001",
    date: "2026-10-31",
    highlights: [],
    changes: [],
    whatsNew: {
      version: "1.0.0-nightly.4124615690001",
      channel: "nightly",
      date: "2026-10-31",
      headline: { en: "" },
      entries: [
        entry(
          "links",
          "improved",
          "Links reuse the browser pane beside your chat",
          "A link opens in the pane you already have. Unread dots wait for background agents.",
        ),
        entry("cost", "new", "Each machine shows its cost", "In the sidebar, next to its name."),
      ],
    },
  },
  {
    build: "4037004604601",
    shortVersion: "1.0.0-nightly.4037004604601",
    date: "2026-10-26",
    highlights: [],
    changes: ["cmux-next sidebar: rows keep their place while you rename them (#28001)"],
    items: [{ title: "cmux-next sidebar: rows keep their place while you rename them", pr: 28001 }],
  },
];

test("the page opens as the What's New sheet unless a route names another design", async () => {
  const { parseDesign } = await import("../src/pages/changelog/store");
  expect(parseDesign("")).toBe("sheet");
  expect(parseDesign("#/?from=1&to=2")).toBe("sheet");
  expect(parseDesign("#/?design=ledger")).toBe("ledger");
  expect(parseDesign("#/?design=nonsense")).toBe("sheet");
});

test("each change is an icon, a bold one-line title and one muted line, newest day first", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => void mountChangelogPage(root, new MockChangelogProvider(notes) as never));
  for (let tries = 0; tries < 200 && root.querySelectorAll(".cls-row").length < 3; tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  expect(root.querySelector(".cls h1")?.textContent).toBe("What's New");
  const days = [...root.querySelectorAll(".cls-day time")].map((t) => t.getAttribute("dateTime"));
  expect(days).toEqual(["2026-10-31", "2026-10-26"]);
  const rows = [...root.querySelectorAll(".cls-row")];
  for (const row of rows) {
    expect(row.querySelector(".cls-icon svg")).not.toBeNull();
    expect(row.querySelectorAll(".cls-row-title").length).toBe(1);
    expect(row.querySelectorAll(".cls-row-line").length).toBeLessThanOrEqual(1);
  }
  const text = (row: Element) => [
    row.querySelector(".cls-row-title")?.textContent,
    row.querySelector(".cls-row-line")?.textContent,
  ];
  // A curated change's summary is cut to its first sentence.
  expect(rows.map(text)).toEqual([
    ["Each machine shows its cost", "In the sidebar, next to its name."],
    ["Links reuse the browser pane beside your chat", "A link opens in the pane you already have."],
    // A change with no curated note: its readable title, and the area it is in as its line.
    ["Rows keep their place while you rename them", "Sidebar"],
  ]);
  // Less text: no version tags, build numbers, pull request chips or category headings.
  expect(root.querySelector(".cll-version, .cl-build, a.cl-pr, .cl-group h3")).toBeNull();
  expect(root.querySelector(".cls")?.textContent).not.toContain("4124615");
});
