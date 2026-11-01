// Conductor-quality What's New (2026-10-20: "our changelog needs to match Conductor's changelog in
// quality, with our own design language"). A Ledger release has a title (the release's curated
// headline), each change with a picture shows it, and the update-ready popover groups the rest of
// the update under New / Improved / Fixed, as Conductor's release pages do.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "location",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.changelog/#/?design=ledger" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
  });
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const pic = "data:image/png;base64,iVBORw0KGgo=";
const entry = (id: string, category: "new" | "improved" | "fixed", title: string, media = false) => ({
  id,
  category,
  title: { en: title },
  summary: { en: `${title}, in one sentence.` },
  ...(media ? { media: { kind: "image", light: pic, dark: pic, alt: { en: title } } } : {}),
});

test("a curated release headline titles its Ledger release", async () => {
  const { releaseTitle } = await import("../src/pages/changelog/model");
  const base = { build: "1", shortVersion: "1.0.0-nightly.1", date: "2026-10-20", highlights: [], changes: [] };
  const doc = (headline: string, entries: unknown[]) => ({
    version: "1.0.0-nightly.1",
    channel: "nightly" as const,
    date: "2026-10-20",
    headline: { en: headline },
    entries: entries as never,
  });
  expect(releaseTitle([{ ...base, whatsNew: doc("Agents can use your apps", [entry("a", "new", "A")]) }], "en")).toBe(
    "Agents can use your apps",
  );
  // A release with no curated entry has no title of its own (the page says "Maintenance and fixes").
  expect(releaseTitle([{ ...base, whatsNew: doc("Fixes and improvements", []) }], "en")).toBeUndefined();
  expect(releaseTitle([base], "en")).toBeUndefined();
});

test("every change with a picture shows it in the Ledger, not only the lead one", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const notes = [
    {
      build: "3937488754201",
      shortVersion: "1.0.0-nightly.3937488754201",
      date: "2026-10-20",
      highlights: [],
      changes: [],
      whatsNew: {
        version: "1.0.0-nightly.3937488754201",
        channel: "nightly",
        date: "2026-10-20",
        headline: { en: "Computer Use and every chat in one place" },
        entries: [
          entry("cu", "new", "Turn on Computer Use in Settings", true),
          entry("chats", "new", "Every chat on your Mac, in one place", true),
          entry("open", "fixed", "cmux open opens URLs, also from stdin"),
        ],
      },
    },
  ];
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  await act(async () => void mountChangelogPage(host, new MockChangelogProvider(notes as never) as never));
  // The notes load from the provider, then the release draws.
  for (let tries = 0; tries < 200 && !host.querySelector(".cll .cll-release"); tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  const release = host.querySelector(".cll .cll-release");
  expect(release?.querySelector(".cll-title")?.textContent).toBe("Computer Use and every chat in one place");
  // The lead picture (hero) and the second change's own picture.
  expect(release?.querySelectorAll("figure img").length).toBe(2);
  expect(release?.querySelector(".cl-group .cl-row-media img")?.getAttribute("alt")).toBe(
    "Every chat on your Mac, in one place",
  );
});

test("the popover groups the rest of the update under New, Improved and Fixed", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  const item = (n: number, category: "new" | "improved" | "fixed") => ({
    id: `c${n}`,
    title: `Change ${n}`,
    summary: null,
    category,
  });
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={{
          version: "1.0.0-nightly.42",
          build: "42",
          fromVersion: "1.0.0-nightly.41",
          fromBuild: "41",
          source: "whatsNew",
          language: "en",
          items: [item(1, "new"), item(2, "new"), item(3, "new")],
          rest: [item(4, "new"), item(5, "improved"), item(6, "fixed"), item(7, "fixed")],
          moreCount: 4,
          changelog: { from: "1.0.0-nightly.41", to: "1.0.0-nightly.42" },
        }}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined }}
      />,
    ),
  );
  const headings = [...host.querySelectorAll(".wn-pop-rest-group h4")].map((h) => h.textContent);
  expect(headings).toEqual(["New", "Improved", "Fixed"]);
  const fixed = host.querySelectorAll(".wn-pop-rest-group")[2];
  expect([...(fixed?.querySelectorAll("li") ?? [])].map((li) => li.textContent)).toEqual(["Change 6", "Change 7"]);
});
