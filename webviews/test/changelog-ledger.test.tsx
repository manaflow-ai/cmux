// u5099 (2026-10-20, "make more variations of changelog, use conductor.build/changelog for
// inspiration"): the What's New page opens in design #01 Ledger of
// design/changelog-variations-gallery. Each release day reads like a Conductor release: its
// version as a small tag and its date in the left margin, then its changes under New / Improved /
// Fixed headings. The older designs stay reachable with `design=` (Debug Settings).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

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

test("the page opens in the Ledger design unless a route names another one", async () => {
  const { parseDesign } = await import("../src/pages/changelog/store");
  expect(parseDesign("")).toBe("ledger");
  expect(parseDesign("#/?from=1&to=2")).toBe("ledger");
  expect(parseDesign("#/?design=journal")).toBe("journal");
  expect(parseDesign("#/?design=rail")).toBe("rail");
  expect(parseDesign("#/?design=nonsense")).toBe("ledger");
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
  await act(async () => {
    mountChangelogPage(root, new MockChangelogProvider(notes) as never);
    await new Promise((resolve) => setTimeout(resolve, 20));
  });
  const page = root.querySelector(".cll");
  expect(page).not.toBeNull();
  const release = root.querySelector(".cll .clj-section");
  expect(release?.querySelector(".cll-version")?.textContent).toBe("nightly 3937488");
  expect(release?.querySelector(".cll-gutter time")?.getAttribute("dateTime")).toBe("2026-10-20");
  const headings = [...(release?.querySelectorAll(".cl-group h3") ?? [])].map((h) => h.textContent);
  expect(headings).toEqual(["New", "Fixed"]);
  expect(release?.textContent).toContain("Add your own coding agent");
});
