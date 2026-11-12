// l10n-allow-file: test fixtures.
// Lawrence 2026-11-09, on the Updated card's changes popover ("Updated to Nightly", the Agent Chat
// list, "+162 more"): "make and show me more versions of this ui". Debug Settings
// `sidebar.updatedCard.notesLook` picks the look live through the theme's `updated-notes-look` slot;
// `sections` ships. Each look shows every change it promises and opens What's New from it.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { teardownDom } from "./support/domTeardown";

const titles = [
  "Agent chats show what is new since you looked",
  "The sidebar keeps unread chats at the top",
  "Browser tabs keep their scroll position",
  "Terminal panes split from the palette",
  "Settings search finds shortcuts by key",
];
const data: UpdateHighlights = {
  version: "1.0.0-nightly.4241815985601",
  build: "4241815985601",
  fromVersion: "1.0.0-nightly.4230000000001",
  fromBuild: "4230000000001",
  source: "whatsNew",
  language: "en",
  items: titles
    .slice(0, 3)
    .map((title, index) => ({ id: `c${index}`, title, summary: `Detail ${index}`, category: "new" as const })),
  rest: titles
    .slice(3)
    .map((title, index) => ({ id: `r${index}`, title, summary: null, category: "improved" as const })),
  moreCount: 2,
  changelog: { from: "1.0.0-nightly.4230000000001", to: "1.0.0-nightly.4241815985601" },
};

describe("the Updated card's changes popover looks", () => {
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "IS_REACT_ACT_ENVIRONMENT",
    "ResizeObserver",
    "requestAnimationFrame",
  ] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  let dom: JSDOM;
  let root: Root | undefined;

  beforeAll(() => {
    dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated-notes" });
    const { window } = dom;
    Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get(this: HTMLElement) {
        return this.classList.contains("wn-preview-body") ? 120 : 0;
      },
    });
    Object.assign(scope, {
      window,
      document: window.document,
      navigator: window.navigator,
      HTMLElement: window.HTMLElement,
      Element: window.Element,
      Node: window.Node,
      IS_REACT_ACT_ENVIRONMENT: true,
      ResizeObserver: class {
        observe() {}
        disconnect() {}
        unobserve() {}
      },
      requestAnimationFrame: () => 0,
    });
  });

  afterAll(async () => {
    act(() => root?.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });

  async function mount(node: React.ReactNode) {
    const { createRoot } = await import("react-dom/client");
    act(() => root?.unmount());
    const host = dom.window.document.getElementById("root")!;
    root = createRoot(host);
    await act(async () => root!.render(node));
    return host;
  }

  async function notes(look: string | null) {
    const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    const html = dom.window.document.documentElement;
    if (look) html.setAttribute("data-cmux-decoration-updated-notes-look", look);
    else html.removeAttribute("data-cmux-decoration-updated-notes-look");
    const opened: unknown[] = [];
    const host = await mount(
      <UpdatedNotes
        data={data}
        strings={createStrings(table)}
        actions={{ openChangelog: (at?: unknown) => opened.push(at ?? "page") }}
        mode="beside"
      />,
    );
    return { host, opened };
  }
  const shownTitles = (host: HTMLElement) =>
    [...host.querySelectorAll(".wn-notes-row-title")].map((t) => t.textContent);

  test("without a look the shipped sections show every change under area headers", async () => {
    const { host } = await notes(null);
    expect(host.querySelector('.wn-notes-list[data-look="sections"]')).not.toBeNull();
    expect(shownTitles(host).sort()).toEqual([...titles].sort());
  });

  test("digest: one line per area, closed; a click opens that area's changes in place", async () => {
    const { host } = await notes("digest");
    const heads = [...host.querySelectorAll<HTMLButtonElement>(".wn-notes-digest-head")];
    expect(heads.length).toBeGreaterThan(0);
    expect(shownTitles(host)).toEqual([]);
    expect(heads[0]!.getAttribute("aria-expanded")).toBe("false");
    await act(async () => heads[0]!.click());
    expect(heads[0]!.getAttribute("aria-expanded")).toBe("true");
    expect(shownTitles(host).length).toBeGreaterThan(0);
  });

  test("chips: All lists every change; an area's chip lists only its changes", async () => {
    const { host } = await notes("chips");
    const chips = [...host.querySelectorAll<HTMLButtonElement>(".wn-notes-chip")];
    expect(chips[0]!.getAttribute("aria-pressed")).toBe("true");
    expect(shownTitles(host)).toHaveLength(titles.length);
    const area = chips[1]!;
    const count = Number(area.querySelector(".wn-notes-area-count")!.textContent);
    await act(async () => area.click());
    expect(area.getAttribute("aria-pressed")).toBe("true");
    expect(shownTitles(host)).toHaveLength(count);
  });

  test("headline: the first three changes with their details, then See all changes with the rest's count", async () => {
    const { host, opened } = await notes("headline");
    expect(shownTitles(host)).toEqual(titles.slice(0, 3));
    expect(host.querySelector(".wn-notes-headline-detail")?.textContent).toBe("Detail 0");
    const seeAll = host.querySelector<HTMLButtonElement>(".wn-notes-seeall")!;
    expect(seeAll.textContent).toContain("+2 more");
    await act(async () => seeAll.click());
    expect(opened).toEqual(["page"]);
  });

  test("ledger: every change on its own line, each area named once", async () => {
    const { host } = await notes("ledger");
    expect(shownTitles(host).sort()).toEqual([...titles].sort());
    const labels = [...host.querySelectorAll(".wn-notes-ledger-area")].map((l) => l.textContent).filter(Boolean);
    expect(new Set(labels).size).toBe(labels.length);
  });
});
