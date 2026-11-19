// l10n-allow-file: test fixtures.
// What the changelog lists show of a row that is not drawn: the Updated card's "+N more" counts the
// rows of every group under the view, wherever the group starts in the card (UpdatedNotes
// useRowsBelow, each group's measurements past its own start); a link to a change of a day far
// down a long What's New index draws that day, scrolls to the change and marks it (SheetPage
// useFocusDay, useFocusScroll); J and K find the next day drawn; and the row or day holding the
// keyboard focus stays drawn, and focused, however far the list scrolls (JournalPage useDayWindow,
// UpdatedNotes WindowedRows).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { IndexEntry, ReleaseNotes } from "../src/pages/changelog/types";
import type { ChangelogFocus, UpdateSpan } from "../src/pages/changelog/store";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { teardownDom } from "./support/domTeardown";

/** Layout jsdom does not do: a card row is 52 px (the rows' guess), the card's scroller 624 px, a
    What's New day 300 px. */
const ROW = 52;
const CARD = 624;
const DAY = 300;
/** What scrollIntoView was asked to show: each target's text. */
const scrolled: string[] = [];

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  const { window } = dom;
  const size = (el: HTMLElement) =>
    el.classList.contains("wn-notes")
      ? CARD
      : el.tagName === "LI" && el.hasAttribute("data-index") && el.closest(".wn-notes")
        ? ROW
        : el.classList.contains("clj-section")
          ? DAY
          : 0;
  // As a browser's: each observed box reports its size once after layout.
  class ResizeObserver {
    private live = true;
    constructor(private readonly changed: (entries: unknown[]) => void) {}
    observe(target: HTMLElement) {
      const height = size(target);
      const entry = {
        target,
        contentRect: { width: 320, height },
        borderBoxSize: [{ inlineSize: 320, blockSize: height }],
      };
      setTimeout(() => this.live && this.changed([entry]), 0);
    }
    unobserve() {}
    disconnect() {
      this.live = false;
    }
  }
  for (const name of ["offsetHeight", "clientHeight"])
    Object.defineProperty(window.HTMLElement.prototype, name, {
      configurable: true,
      get(this: HTMLElement) {
        return size(this);
      },
    });
  // A card group's list starts under the groups above it: each group's rows end to end, no headers.
  const rect = window.Element.prototype.getBoundingClientRect;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const card = this.closest<HTMLElement>(".wn-notes");
    if (card && this.classList.contains("wn-notes-rows")) {
      const groups = [...card.querySelectorAll(".wn-notes-rows")];
      const top = groups.indexOf(this) * GROUP * ROW - card.scrollTop;
      return { top, bottom: top, left: 0, right: 0, width: 0, height: 0, x: 0, y: top, toJSON() {} } as DOMRect;
    }
    // A drawn day stands at its place in the index (the day list starts at the page's top).
    const index = this.getAttribute("data-index");
    if (this.classList.contains("clj-section") && index !== null) {
      const top = Number(index) * DAY - window.scrollY;
      return { top, bottom: top + DAY, left: 0, right: 0, width: 0, height: DAY, x: 0, y: top, toJSON() {} } as DOMRect;
    }
    return rect.call(this);
  };
  window.HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    scrolled.push(this.textContent ?? "");
  };
  Object.assign(window, { ResizeObserver, scrollTo: () => {}, matchMedia: () => ({ matches: false }) });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver,
  });
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = async () => {
  for (let i = 0; i < 5; i++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
};

async function mount(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  act(() => root?.unmount());
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(node));
  await settle();
  return host;
}

async function strings() {
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  return createStrings(table);
}

/** Each group's rows: the card's three groups (New, Improved, Fixed; or three areas) of GROUP each. */
const GROUP = 100;
const AREAS = ["Sidebar", "Terminal", "Browser"] as const;

/** 3 × GROUP changes: New, Improved and Fixed in turn, each naming one of three areas in turn. */
function update(): UpdateHighlights {
  const kinds = ["new", "improved", "fixed"] as const;
  const items = Array.from({ length: 3 * GROUP }, (_, i) => ({
    id: `c${i}`,
    title: `${AREAS[i % 3]} keeps its place after change ${i}`,
    summary: `The detail of change ${i}.`,
    category: kinds[i % 3]!,
  }));
  return {
    version: "1.0.0-nightly.5000000000000",
    build: "5000000000000",
    fromVersion: "1.0.0-nightly.4000000000000",
    fromBuild: "4000000000000",
    source: "whatsNew",
    language: "en",
    items: items.slice(0, 3),
    rest: items.slice(3),
    moreCount: 3 * GROUP - 3,
    changelog: { from: "1.0.0-nightly.4000000000000", to: "1.0.0-nightly.5000000000000" },
  };
}

describe("the Updated card's count of rows below", () => {
  for (const look of ["release", "sections"] as const)
    test(`the ${look} look counts the rows of every group under the view, drawn or not`, async () => {
      const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
      const card = await mount(
        <UpdatedNotes
          data={update()}
          strings={await strings()}
          actions={{ openChangelog: () => {} }}
          mode="beside"
          look={look}
        />,
      );
      const groups = card.querySelectorAll(".wn-notes-rows");
      expect(groups.length).toBe(3);
      const more = () => Number(/\d+/.exec(card.querySelector(".wn-notes-more")?.textContent ?? "")?.[0]);
      // The view shows the first group's first 12 rows (624 / 52): every other row is below it.
      expect(more()).toBe(3 * GROUP - CARD / ROW);

      // Scrolled into the second group: its rows above the view's bottom, and the whole first group,
      // are not below.
      const scroller = card.querySelector<HTMLElement>(".wn-notes")!;
      const offset = (GROUP + 20) * ROW;
      Object.defineProperty(scroller, "scrollTop", { configurable: true, value: offset });
      await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
      await settle();
      expect(more()).toBe(3 * GROUP - (offset + CARD) / ROW);
    }, 60_000);
});

/** One build a day, newest first, from 2026-11-18 back; each day's one change names its date. */
function index(count: number): IndexEntry[] {
  return Array.from({ length: count }, (_, i) => {
    const build = String(5_000_000_000_000 - i);
    const date = new Date(Date.UTC(2026, 10, 18) - i * 86_400_000).toISOString().slice(0, 10);
    return { build, shortVersion: `1.0.0-nightly.${build}`, date, highlights: 1 };
  });
}

const titleOf = (date: string) => `Tabs keep their place on day ${date}`;

const notesOf = (b: IndexEntry): ReleaseNotes => ({
  build: b.build,
  shortVersion: b.shortVersion,
  date: b.date,
  highlights: [],
  changes: [`${titleOf(b.date)} (#30000)`],
  items: [{ title: titleOf(b.date), pr: 30_000 }],
});

function client(builds: IndexEntry[]): PageClient {
  const byBuild = new Map(builds.map((b) => [b.build, b]));
  return {
    async call(op: string, params: { build?: string }) {
      if (op === "cmux.changelog.list") return { current: builds[0]!.build, builds };
      if (op === "cmux.changelog.get") {
        const b = byBuild.get(params.build ?? "");
        if (!b) throw new Error("not found");
        return notesOf(b);
      }
      return {};
    },
  } as unknown as PageClient;
}

/** A `design` page over `count` days, opened at `focus` (and the update's `span`), settled. */
async function page(count: number, focus?: ChangelogFocus, span?: UpdateSpan, design: "sheet" | "journal" = "sheet") {
  const { ChangelogStore } = await import("../src/pages/changelog/store");
  const { ChangelogPage } = await import("../src/pages/changelog/ChangelogPage");
  const store = new ChangelogStore(client(index(count)));
  await store.start(span);
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: 0 });
  const host = await mount(<ChangelogPage store={store} strings={await strings()} design={design} focus={focus} />);
  for (let i = 0; i < 40 && focus && !host.querySelector("[data-focus]"); i++) await settle();
  return host;
}
const sheet = (count: number, focus: ChangelogFocus, span?: UpdateSpan) => page(count, focus, span);

async function scrollWindow(y: number) {
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: y });
  await act(async () => void dom.window.dispatchEvent(new dom.window.Event("scroll")));
  await settle();
}

const drawnDays = (host: HTMLElement) =>
  [...host.querySelectorAll<HTMLElement>(".clj-section[data-index]")].map((day) => Number(day.dataset.index));

describe("a link to a change of a day far down What's New", () => {
  const far = index(1_000)[900]!;

  for (const [name, span] of [
    ["with no update", undefined],
    ["outside the update's day", { from: index(1_000)[1]!.shortVersion, to: index(1_000)[0]!.shortVersion }],
  ] as const)
    test(`${name}: draws that day, scrolls to the change and marks it`, async () => {
      scrolled.length = 0;
      const page = await sheet(1_000, { area: "tabs", entry: titleOf(far.date), n: "k1" }, span);
      const days = [...page.querySelectorAll<HTMLElement>(".cls-day")];
      // The day is drawn among a screen of others, never the whole index.
      expect(days.map((day) => day.querySelector("time")?.getAttribute("dateTime"))).toContain(far.date);
      expect(days.length).toBeLessThanOrEqual(14);
      const row = [...page.querySelectorAll<HTMLElement>(".cls-row")].find((el) => el.textContent?.includes(far.date));
      expect(row?.hasAttribute("data-focus")).toBe(true);
      expect(scrolled.length).toBe(1);
      expect(scrolled[0]).toContain(far.date);
    }, 60_000);
});

describe("a focus on a long What's New index waits for its target", () => {
  test("an area with no change named stays on the newest day's section in a long index", async () => {
    scrolled.length = 0;
    const host = await sheet(1_000, { area: "tabs", n: "a1" });
    expect(host.querySelector(".cls-day[data-index='0'] .cls-area[data-area=tabs]")?.hasAttribute("data-focus")).toBe(
      true,
    );
    expect(scrolled.length).toBe(1);
  }, 60_000);

  test("a change no day lists falls back to its area once the whole index is read", async () => {
    scrolled.length = 0;
    const host = await sheet(1_000, { area: "tabs", entry: "A change no build lists", n: "a2" });
    expect(host.querySelector(".cls-area[data-area=tabs]")?.hasAttribute("data-focus")).toBe(true);
    expect(host.querySelectorAll(".cls-day").length).toBeLessThanOrEqual(14);
    expect(scrolled.length).toBe(1);
  }, 60_000);
});

describe("the keyboard on a long What's New index", () => {
  for (const design of ["sheet", "journal"] as const) {
    test(`${design}: J and K from the middle of a long index find the next and previous day drawn`, async () => {
      const host = await page(1_000, undefined, undefined, design);
      await scrollWindow(500 * DAY);
      const days = drawnDays(host);
      expect(days).toContain(499);
      expect(days).toContain(501);
      expect(days.length).toBeLessThanOrEqual(12);
      const at = host.querySelector<HTMLElement>(".clj-section[data-index='500']")!;
      for (const [key, next] of [
        ["j", 501],
        ["k", 499],
      ] as const) {
        scrolled.length = 0;
        await act(async () => void at.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true })));
        const want = host.querySelector(`.clj-section[data-index='${next}'] time`)!.getAttribute("dateTime")!;
        expect(scrolled.length).toBe(1);
        expect(scrolled[0]).toContain(want.slice(0, 4));
      }
    }, 60_000);

    test(`${design}: the day holding the focus stays drawn and focused when the page scrolls far away`, async () => {
      const host = await page(1_000, undefined, undefined, design);
      const control = host.querySelector<HTMLElement>(
        ".clj-section[data-index='0'] button, .clj-section[data-index='0'] summary",
      )!;
      expect(control).not.toBeNull();
      await act(async () => control.focus());
      await scrollWindow(600 * DAY);
      expect(control.isConnected).toBe(true);
      expect(dom.window.document.activeElement).toBe(control);
      expect(drawnDays(host)).toContain(0);
      expect(drawnDays(host).length).toBeLessThanOrEqual(13);
    }, 60_000);
  }
});

describe("the Updated card's row holding the focus", () => {
  for (const look of ["release", "sections", "flat"] as const)
    test(`${look}: stays drawn and focused when the card scrolls far away`, async () => {
      const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
      const card = await mount(
        <UpdatedNotes
          data={update()}
          strings={await strings()}
          actions={{ openChangelog: () => {} }}
          mode="beside"
          look={look}
        />,
      );
      const first = card.querySelector<HTMLElement>(".wn-notes-row")!;
      const title = first.textContent;
      await act(async () => first.focus());
      const scroller = card.querySelector<HTMLElement>(".wn-notes")!;
      const group = first.closest<HTMLElement>("ul")!;
      // Scrolled within its group, then past it: the row stays, and the group keeps its height
      // (its padding, the room between the focused row and the rows near the view, and the rows).
      for (const offset of [60 * ROW, (2 * GROUP + 50) * ROW]) {
        Object.defineProperty(scroller, "scrollTop", { configurable: true, value: offset });
        await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
        await settle();
        expect(first.isConnected).toBe(true);
        expect(dom.window.document.activeElement).toBe(first);
        expect(first.textContent).toBe(title);
        const rows = group.querySelectorAll("li[data-index]").length;
        const room = [...group.querySelectorAll<HTMLElement>("li[aria-hidden]")].reduce(
          (sum, li) => sum + Number.parseFloat(li.style.height),
          0,
        );
        const padding = Number.parseFloat(group.style.paddingTop) + Number.parseFloat(group.style.paddingBottom);
        expect(padding + room + rows * ROW).toBe((look === "flat" ? 3 * GROUP : GROUP) * ROW);
        // The rows near the view drawn, and that one; the rest stays room.
        expect(card.querySelectorAll(".wn-notes-row").length).toBeLessThanOrEqual(3 * 45);
      }
    }, 60_000);
});
