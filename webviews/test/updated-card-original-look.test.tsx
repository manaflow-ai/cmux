// l10n-allow-file: test fixtures.
// The sidebar's Updated card keeps its two-line look (Lawrence 2026-11-23, on the one-line card from
// #51908 that read "Update... What's New ↗": "this update thing is ugly now (the button) just revert
// the bottom left button thing to what it originally was"). The resting card says "Updated to
// Nightly" alone on its first line, so the title is never cut to fit What's New beside it, and the
// update's top change on its second line; What's New leads the open preview.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const data: UpdateHighlights = {
  version: "1.0.0-nightly.4527560139601",
  build: "4527560139601",
  fromVersion: "1.0.0-nightly.4520000000000",
  fromBuild: "4520000000000",
  date: "2026-11-23",
  source: "summary",
  language: "en",
  items: [
    { id: "a", title: "A Lock Screen style clock above the composer", summary: null, category: "improved" },
    { id: "b", title: "A reply between turns keeps one row id", summary: null, category: "fixed" },
  ],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.4520000000000", to: "1.0.0-nightly.4527560139601" },
};

// The card as the sidebar mounts it (surface.tsx): no look props, so the shipped look.
async function renderShippedCard() {
  const { createRoot } = await import("react-dom/client");
  const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  const noop = () => undefined;
  await act(async () =>
    root!.render(
      <UpdatedCard data={data} strings={createStrings(table)} actions={{ openChangelog: noop, dismiss: noop }} />,
    ),
  );
}

test("the resting Updated card's first line is the title alone, with no What's New beside it", async () => {
  await renderShippedCard();
  const head = host.querySelector(".wn-card-head");
  expect(head).not.toBeNull();
  expect(head!.querySelector(".wn-card-link")).toBeNull();
  expect(head!.textContent).toBe("Updated to Nightly");
});

test("the resting Updated card's second line is the update's top change", async () => {
  await renderShippedCard();
  const notes = [...host.querySelectorAll(".wn-card-rest > .wn-card-note")].map((n) => n.textContent);
  expect(notes).toHaveLength(1);
  expect(notes[0]).toContain("Lock Screen style clock");
});
