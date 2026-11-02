// u5099 (2026-10-20, "make more variations of changelog, use conductor.build/changelog for
// inspiration"): the What's New page opens in design #01 Ledger of
// design/changelog-variations-gallery. Each release day reads like a Conductor release: its
// version as a small tag and its date in the left margin, then its changes under New / Improved /
// Fixed headings. Since 2026-10-31 the What's New sheet is the default (whats-new-sheet.test.tsx);
// the Ledger and the older designs stay reachable with `design=` (Debug Settings).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.changelog/#/?design=ledger" });
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

test("a route names the Ledger and the older designs", async () => {
  const { parseDesign } = await import("../src/pages/changelog/store");
  expect(parseDesign("#/?design=ledger")).toBe("ledger");
  expect(parseDesign("#/?design=ledger&from=1&to=2")).toBe("ledger");
  expect(parseDesign("#/?design=journal")).toBe("journal");
  expect(parseDesign("#/?design=rail")).toBe("rail");
});

test("a Ledger release shows its version tag and date in the margin and its changes under headings", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const notes = [
    {
      build: "3937488754201",
      shortVersion: "1.0.0-nightly.3937488754201",
      date: "2026-10-20",
      highlights: [],
      summary: [
        { group: "new", title: "Add your own coding agent" },
        { group: "fixed", title: "cmux open opens URLs, also from stdin" },
      ],
      changes: [],
    },
  ];
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => void mountChangelogPage(root, new MockChangelogProvider(notes) as never));
  // The notes load from the provider, then the release draws.
  for (let tries = 0; tries < 200 && !root.querySelector(".cll .clj-section"); tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  const page = root.querySelector(".cll");
  expect(page).not.toBeNull();
  const release = root.querySelector(".cll .clj-section");
  expect(release?.querySelector(".cll-version")?.textContent).toBe("nightly 3937488");
  expect(release?.querySelector(".cll-gutter time")?.getAttribute("dateTime")).toBe("2026-10-20");
  const headings = [...(release?.querySelectorAll(".cl-group h3") ?? [])].map((h) => h.textContent);
  expect(headings).toEqual(["New", "Fixed"]);
  expect(release?.textContent).toContain("Add your own coding agent");
});

test("a Ledger row shows its whole description, with its picture beside the text", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const picture = "data:image/gif;base64,R0lGODlhAQABAAAAACw=";
  const entry = (id: string, category: "new" | "improved", title: string, summary: string, media?: boolean) => ({
    id,
    category,
    title: { en: title },
    summary: { en: summary },
    ...(media ? { media: { kind: "image", light: picture, dark: picture, alt: { en: `${title} picture` } } } : {}),
  });
  const notes = [
    {
      build: "3937488754202",
      shortVersion: "1.0.0-nightly.3937488754202",
      date: "2026-10-21",
      highlights: [],
      changes: [],
      whatsNew: {
        version: "1.0.0-nightly.3937488754202",
        channel: "nightly",
        date: "2026-10-21",
        headline: { en: "Lead" },
        entries: [
          entry("lead", "new", "Lead", "The lead change.", true),
          entry("bands", "improved", "Bands", "First paragraph.\n\nSecond paragraph.", true),
        ],
      },
    },
  ];
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => {
    mountChangelogPage(root, new MockChangelogProvider(notes as never) as never);
  });
  // Until the notes load and the row renders: a condition, not a fixed delay. Each turn is its own
  // act, so React commits to the DOM before the next check.
  for (let turn = 0; turn < 50 && !root.querySelector(".cl-has-media"); turn++)
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  const row = root.querySelector<HTMLElement>(".cll .cl-group li.cl-has-media")!;
  expect(row.querySelector(".cl-row-title")?.textContent).toBe("Bands");
  expect([...row.querySelectorAll(".cl-row-summary")].map((p) => p.textContent)).toEqual([
    "First paragraph.",
    "Second paragraph.",
  ]);
  // The picture is the row's second column, not part of its text.
  const media = row.querySelector(".cl-row-media");
  expect(media?.parentElement).toBe(row);
  expect(row.querySelector(".cl-row-text .cl-row-media")).toBeNull();
  expect(media?.querySelector("img")?.getAttribute("alt")).toBe("Bands picture");
});
