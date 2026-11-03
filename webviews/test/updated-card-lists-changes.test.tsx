// l10n-allow-file: test fixtures.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
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

// Lawrence 2026-10-31 (msg 19218): "it looks like too much text". The default picked from the
// gallery (cmux-shots/whatsnew-variations): the title, the one top change and a What's New button.
// No date, build line, change list or "+N more" (it said "Updated to Nightly · Oct 31 at 4:01 PM /
// Build e7a61ac · Newest", three areas and "+8 more"). The full build is in About, and a click on
// the version in the title copies it.
const data: UpdateHighlights = {
  version: "1.0.0-nightly.3934171000001",
  build: "3934171000001",
  fromVersion: "1.0.0-nightly.3913596493801",
  fromBuild: "3913596493801",
  date: "2026-10-19",
  builtAt: "2026-10-19T12:00:00Z",
  head: "a9d1434de781a18ebae84d93d2b5a803864f5839",
  source: "whatsNew" as const,
  language: "en",
  items: [
    {
      id: "dictation",
      title: "Dictation progress is announced to VoiceOver",
      summary: "Hears recording.",
      category: "fixed" as const,
    },
    { id: "new-tab", title: "New Tab names its project and machine at once", summary: null, category: "new" as const },
    { id: "smooth", title: "Chats stay smooth while an agent streams", summary: null, category: "improved" as const },
  ],
  moreCount: 35,
  changelog: { from: "1.0.0-nightly.3913596493801", to: "1.0.0-nightly.3934171000001" },
};

async function renderCard(d: UpdateHighlights) {
  const { createRoot } = await import("react-dom/client");
  const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  const noop = () => undefined;
  await act(async () =>
    root!.render(
      <UpdatedCard data={d} strings={createStrings(table)} actions={{ openChangelog: noop, dismiss: noop }} />,
    ),
  );
}

test("the Updated card is the title, the one top change and What's New", async () => {
  await renderCard(data);
  expect(host.querySelector(".wn-card-title")?.textContent).toBe("Updated to Nightly");
  const notes = [...host.querySelectorAll(".wn-card-note")].map((n) => n.textContent);
  expect(notes).toEqual(["Composer: dictation progress is announced to VoiceOver"]);
  const buttons = [...host.querySelectorAll("button")].map((b) => b.textContent || b.getAttribute("aria-label"));
  // The version in the title is the copy button (CopyVersion), then the card's own two.
  expect(buttons).toEqual(["Nightly", "Close", "What's New"]);
  // No date, build, list or count.
  expect(host.querySelector(".wn-card-eyebrow, .wn-card-build, .wn-card-areas, .wn-card-more")).toBeNull();
  const text = host.textContent ?? "";
  for (const gone of ["Oct", "Build", "3934171", "a9d1434", "more", "New Tab", "smooth"])
    expect(text).not.toContain(gone);
  // And no tooltip over any of it (2026-10-31: "seems excessive").
  expect(host.querySelector(".wn-card [title]")).toBeNull();
});

test("a release version reads as itself", async () => {
  await renderCard({ ...data, version: "1.2.0" });
  expect(host.querySelector(".wn-card-title")?.textContent).toBe("Updated to 1.2.0");
});

test("a click on the version in the title copies the full build and says Copied", async () => {
  const copied: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  await renderCard(data);
  const version = host.querySelector<HTMLElement>(".wn-card-title .wn-copy-version")!;
  expect(version.textContent).toBe("Nightly");
  // A native button (#29931): focus, Return and Space come from the platform.
  expect(version.tagName).toBe("BUTTON");
  expect(version.getAttribute("type")).toBe("button");
  expect(version.hasAttribute("role")).toBe(false);
  expect(version.getAttribute("aria-label")).toBe("Copy Version 1.0.0-nightly.3934171000001");
  await act(async () => {
    version.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  });
  expect(copied).toEqual(["1.0.0-nightly.3934171000001"]);
  expect(host.querySelector(".wn-card-title")?.textContent).toBe("Updated to Nightly · Copied");
  delete (window.navigator as { clipboard?: unknown }).clipboard;
});

// Return or Space on the focused version is the button's own activation: a click with detail 0. It
// copies even while text elsewhere on the page is selected; only a pointer click that ends a drag
// selects instead.
test("Return or Space on the version copies the full build, with a selection on the page", async () => {
  const copied: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  await renderCard(data);
  const id = host.querySelector<HTMLButtonElement>(".wn-card-title .wn-copy-version")!;
  const eyebrow = host.querySelector(".wn-card-note")!;
  // CopyVersion reads the page's selection from globalThis, which is the window in a page.
  const hadSelection = "getSelection" in scope;
  scope.getSelection = window.getSelection.bind(window);
  // The version has keyboard focus and the card's top change is selected.
  id.focus();
  window.getSelection()!.selectAllChildren(eyebrow);
  expect(window.document.activeElement).toBe(id);
  expect(window.getSelection()!.isCollapsed).toBe(false);
  // A pointer click that ends a selection copies nothing.
  await act(async () => {
    id.dispatchEvent(new window.MouseEvent("click", { bubbles: true, detail: 1 }));
  });
  expect(copied).toEqual([]);
  expect(window.getSelection()!.isCollapsed).toBe(false);
  // The key's activation (what a browser sends for Return or Space on a focused button) copies.
  await act(async () => {
    id.dispatchEvent(new window.MouseEvent("click", { bubbles: true, detail: 0 }));
  });
  expect(copied).toEqual(["1.0.0-nightly.3934171000001"]);
  // Let jsdom's queued selectionchange reach this file's React root, not a later file's.
  await act(async () => {
    window.getSelection()!.removeAllRanges();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  if (!hadSelection) delete scope.getSelection;
  delete (window.navigator as { clipboard?: unknown }).clipboard;
});
