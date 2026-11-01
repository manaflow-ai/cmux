// l10n-allow-file: test fixtures.
// The Updated card summarizes the whole update, grouped by area (whats-new lane, 2026-10-20): it said
// "Updated to Nightly · Oct 20" over one title, the newest commit's subject ("Enroll Computer Use
// after peer check"), even when the update spanned several skipped nightlies. Now every build after
// the previous version counts, each area gets one line ("Sidebar: …; …"), internal work stays out
// and "+N more" counts the user-visible changes not listed.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function notes(build: string, items: { title: string; pr: number }[]): ReleaseNotes {
  return {
    build,
    shortVersion: `1.0.0-nightly.${build}`,
    date: "2026-10-20",
    highlights: [],
    changes: items.map((i) => `${i.title} (#${i.pr})`),
    items,
  };
}

// Three nightlies after the installed one, newest first. The newest has one user-visible commit.
const span: ReleaseNotes[] = [
  notes("3940000000003", [
    { title: "cmux-next: enroll Computer Use after peer check", pr: 101 },
    { title: "ci: shard the gallery capture", pr: 102 },
  ]),
  notes("3940000000002", [
    { title: "cmux-next sidebar: groups made by automation take a palette color, not grey", pr: 201 },
    { title: "cmux-next sidebar: a click never drags", pr: 202 },
    { title: "test(next sidebar): the focus-loss drag test calls pointerFocusLost", pr: 203 },
    { title: "cmux NEXT: a New Tab page opens minimal by default", pr: 204 },
  ]),
  notes("3940000000001", [
    { title: "cmux-next sidebar: an 8 pt margin above the window's bottom edge", pr: 301 },
    { title: "cmux NEXT composer: Return steers a running turn", pr: 302 },
    { title: "fix(cmux-next): the terminal keeps its scrollback after a relaunch", pr: 303 },
    { title: "chore(next): base autofix at 659726b04ea9", pr: 304 },
  ]),
];

const data: UpdateHighlights = {
  version: "1.0.0-nightly.3940000000003",
  build: "3940000000003",
  fromVersion: "1.0.0-nightly.3930000000000",
  fromBuild: "3930000000000",
  date: "2026-10-20",
  source: "summary",
  language: "en",
  // What the host sends for the newest build alone: its one summary line.
  items: [{ id: "summary-0", title: "Enroll Computer Use after peer check", summary: null, category: "improved" }],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.3930000000000", to: "1.0.0-nightly.3940000000003" },
};

async function renderCard(d: UpdateHighlights, s?: ReleaseNotes[]) {
  const { createRoot } = await import("react-dom/client");
  const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  const noop = () => undefined;
  await act(async () =>
    root!.render(
      <UpdatedCard data={d} span={s} strings={createStrings(table)} actions={{ openChangelog: noop, dismiss: noop }} />,
    ),
  );
}

// The card is short now (2026-10-31, "too much text"): it says the update's top change only, the
// first area's first change; the rest is one click away in What's New.
const note = () => [...host.querySelectorAll(".wn-card-note")].map((n) => n.textContent);

test("the Updated card summarizes every skipped nightly by area, not the newest commit's subject", async () => {
  await renderCard(data, span);
  // The newest commit is one change among the rest, never the card's headline.
  expect(note()).toEqual(["Sidebar: groups made by automation take a palette color"]);
  // CI, tests and autofixes stay out; no count of the rest.
  expect(host.querySelector(".wn-card-more")).toBeNull();
  expect(host.textContent).not.toContain("shard");
  expect(host.textContent).not.toContain("autofix");
});

test("without the span's notes the card still groups the host's changes instead of one headline", async () => {
  await renderCard({
    ...data,
    items: [
      { id: "a", title: "Sidebar groups take a palette color", summary: null, category: "improved" },
      { id: "b", title: "A click in the sidebar never drags", summary: null, category: "fixed" },
      { id: "c", title: "Enroll Computer Use after peer check", summary: null, category: "improved" },
    ],
    moreCount: 0,
  });
  expect(note()).toEqual(["Sidebar: sidebar groups take a palette color"]);
});

test("an update with only internal work says Maintenance and fixes", async () => {
  await renderCard({ ...data, items: [], moreCount: 0, source: "none" }, [
    notes("3940000000004", [{ title: "ci: shard the gallery capture", pr: 401 }]),
  ]);
  expect(note()).toEqual(["Maintenance and fixes"]);
  expect(host.querySelector(".wn-card-more")).toBeNull();
});
