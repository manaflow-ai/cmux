// l10n-allow-file: test fixtures.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

// The Updated card lists the update's top changes right on it (u2441, gallery #01 "Compact list",
// 2026-10-19): the user wants to see what's new on the card, not one headline and a button. Every
// listed title shows; the count is only the changes not listed.
const data = {
  version: "1.0.0-nightly.3934171000001",
  build: "3934171000001",
  fromVersion: "1.0.0-nightly.3913596493801",
  fromBuild: "3913596493801",
  date: "2026-10-19",
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

async function renderCard(d: typeof data) {
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

test("the Updated card lists every top change as its own item, then the count of the rest", async () => {
  await renderCard(data);
  const items = [...host.querySelectorAll(".wn-card-changes li")].map((li) => li.textContent);
  expect(items).toEqual(data.items.map((i) => i.title));
  expect(host.querySelector(".wn-card-more")?.textContent).toBe("+35 more");
  const buttons = [...host.querySelectorAll("button")].map((b) => b.textContent || b.getAttribute("aria-label"));
  expect(buttons).toEqual(["Close", "See What's New"]);
});

test("the Updated card with every change listed shows no count", async () => {
  await renderCard({ ...data, moreCount: 0 });
  expect(host.querySelectorAll(".wn-card-changes li").length).toBe(3);
  expect(host.querySelector(".wn-card-more")).toBeNull();
});
