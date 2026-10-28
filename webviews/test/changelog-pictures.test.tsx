// Leo 2026-10-21 (What's New design pass, 2): each change can carry a picture, lazy-loaded in a
// glass frame, that opens enlarged on a click. A nightly's digest entries carry no picture of
// their own; the highlight file's picture (release-notes.py) stands in for its entry.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { releaseView } from "../src/pages/changelog/model";
import type { ReleaseNotes } from "../src/pages/changelog/types";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "Element",
  "getComputedStyle",
  "location",
  "IS_REACT_ACT_ENVIRONMENT",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  // pretendToBeVisual: the lightbox is a Base UI dialog, whose open transition waits a frame.
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    url: "cmux-page://cmux.changelog/",
    pretendToBeVisual: true,
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const picture = "data:image/gif;base64,R0lGODlhAQABAAAAACw=";

function nightly(): ReleaseNotes {
  return {
    build: "3937488754203",
    shortVersion: "1.0.0-nightly.3937488754203",
    date: "2026-10-21",
    changes: [],
    // As release-notes.py writes a highlight: its file name as the id, its PR's picture as media.
    highlights: [
      {
        id: "Group_Band_Colors",
        title: "Group labels keep their band color",
        body: "A label keeps its band's color.",
        category: "improved",
        media: [{ url: picture, sha256: "0".repeat(64), kind: "image", alt: "Groups with colored labels" }],
      },
    ],
    // As digest.py writes the same file: a normalized id and no picture.
    whatsNew: {
      version: "1.0.0-nightly.3937488754203",
      channel: "nightly",
      date: "2026-10-21",
      headline: { en: "Group labels keep their band color" },
      entries: [
        {
          id: "group-band-colors",
          category: "improved",
          title: { en: "Group labels keep their band color" },
          summary: { en: "A label keeps its band's color." },
        },
      ],
    },
  };
}

test("a digest entry with no picture shows its highlight file's picture", () => {
  const view = releaseView(nightly(), "en");
  const items = [view.hero, ...view.groups.flatMap((g) => g.items)].filter((i) => i !== undefined);
  expect(items).toHaveLength(1);
  expect(items[0]!.media?.light).toBe(picture);
  expect(items[0]!.media?.alt).toBe("Groups with colored labels");
});

test("in another language the highlight file and its digest entry stay one change", () => {
  const notes = nightly();
  notes.whatsNew!.entries[0]!.title.ja = "グループのラベルは帯の色を保つ";
  notes.whatsNew!.entries[0]!.summary.ja = "ラベルは帯の色のままです。";
  const view = releaseView(notes, "ja");
  const items = [view.hero, ...view.groups.flatMap((g) => g.items)].filter((i) => i !== undefined);
  expect(items.map((i) => i.title)).toEqual(["グループのラベルは帯の色を保つ"]);
  expect(items[0]!.media?.light).toBe(picture);
});

test("a change's picture opens enlarged on a click, and Close closes it", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => {
    mountChangelogPage(root, new MockChangelogProvider([nightly()] as never) as never);
  });
  // Until the notes load and the picture renders: a condition, not a fixed delay.
  for (let turn = 0; turn < 50 && !root.querySelector(".cl-media-open"); turn++)
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  const open = root.querySelector<HTMLButtonElement>(".cl-media-open")!;
  expect(open.getAttribute("aria-label")).toContain("Groups with colored labels");
  expect(open.querySelector("img")?.getAttribute("loading")).toBe("lazy");
  await act(async () => open.click());
  const doc = dom.window.document;
  for (let turn = 0; turn < 50 && !doc.querySelector(".cl-lightbox img"); turn++)
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(doc.querySelector(".cl-lightbox img")?.getAttribute("src")).toBe(picture);
  const close = [...doc.querySelectorAll<HTMLButtonElement>(".cl-lightbox button")].find((b) =>
    b.textContent?.includes("Close"),
  )!;
  await act(async () => close.click());
  for (let turn = 0; turn < 50 && doc.querySelector(".cl-lightbox"); turn++)
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(doc.querySelector(".cl-lightbox")).toBeNull();
});
