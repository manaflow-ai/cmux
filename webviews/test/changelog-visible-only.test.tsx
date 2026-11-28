// l10n-allow-file: test fixtures.
// What's New and the Updated card's list draw only what is on screen, whatever the list's length:
// the nightly index's days (SheetPage, JournalPage useDayWindow) and the card's changes (UpdatedNotes
// WindowedRows) mount the same few rows at 1,000 and at 10,000; a note that loads, a changed entry
// or a scroll step redraws no row whose data did not change; and a scroll reads no row's box (the
// card's "N more" counts from the rows' measured sizes). Counted through the real components: a day
// draws its date twice (model.ts dayLabel, its label and its <time>), a card row is NotesRow.
import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement, type ComponentProps } from "react";
import type { Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { IndexEntry, ReleaseNotes } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { teardownDom } from "./support/domTeardown";

/// Each day's date drawn, by date.
const dayDraws = new Map<string, number>();
const MODEL = "../src/pages/changelog/model";
const realModel = await import(MODEL);
const realDayLabel = realModel.dayLabel;
void mock.module(MODEL, () => ({
  ...realModel,
  dayLabel: (date: string, language: string, now?: Date) => {
    dayDraws.set(date, (dayDraws.get(date) ?? 0) + 1);
    return realDayLabel(date, language, now);
  },
}));

/// The card's rows drawn, by entry id.
const rowDraws = new Map<string, number>();
const LOOKS = "../src/pages/changelog/UpdatedNotesLooks";
const realLooks = await import(LOOKS);
const RealNotesRow = realLooks.NotesRow;
void mock.module(LOOKS, () => ({
  ...realLooks,
  NotesRow: (props: ComponentProps<typeof RealNotesRow>) => {
    rowDraws.set(props.entry.id, (rowDraws.get(props.entry.id) ?? 0) + 1);
    return createElement(RealNotesRow, props);
  },
}));

const SIZES = [1_000, 10_000] as const;
/** Layout jsdom does not do: a day is 300 px, a card row 40 px, the card's scroller 600 px. */
const DAY = 300;
const ROW = 40;
const CARD = 600;

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
/// getBoundingClientRect calls since the last reset.
let boxReads = 0;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  const { window } = dom;
  class ResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  const size = (el: HTMLElement) =>
    el.classList.contains("wn-notes")
      ? CARD
      : el.tagName === "LI" && el.closest(".wn-notes")
        ? ROW
        : el.classList.contains("clj-section")
          ? DAY
          : 0;
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return size(this);
    },
  });
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return size(this);
    },
  });
  const rect = window.Element.prototype.getBoundingClientRect;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    boxReads += 1;
    return rect.call(this);
  };
  Object.assign(window, { ResizeObserver, scrollTo: () => {} });
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
  mock.restore();
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

/** One build a day, newest first, from 2026-11-18 back. */
function index(count: number): IndexEntry[] {
  return Array.from({ length: count }, (_, i) => {
    const build = String(5_000_000_000_000 - i);
    const date = new Date(Date.UTC(2026, 10, 18) - i * 86_400_000).toISOString().slice(0, 10);
    return { build, shortVersion: `1.0.0-nightly.${build}`, date, highlights: 1 };
  });
}

const notesOf = (b: IndexEntry): ReleaseNotes => ({
  build: b.build,
  shortVersion: b.shortVersion,
  date: b.date,
  highlights: [],
  changes: [`Tabs keep their place on day ${b.date} (#${30_000})`],
  items: [{ title: `Tabs keep their place on day ${b.date}`, pr: 30_000 }],
});

/** A host whose `held` build's notes wait until `release()`; every other build answers at once. */
function host(builds: IndexEntry[], held: string) {
  let release = () => {};
  const waiting = new Promise<void>((resolve) => (release = resolve));
  const byBuild = new Map(builds.map((b) => [b.build, b]));
  const client = {
    async call(op: string, params: { build?: string }) {
      if (op === "cmux.changelog.list") return { current: builds[0]!.build, builds };
      if (op === "cmux.changelog.get") {
        const b = byBuild.get(params.build ?? "");
        if (!b) throw new Error("not found");
        if (b.build === held) await waiting;
        return notesOf(b);
      }
      if (op === "cmux.changelog.installable") return { installs: false };
      return {};
    },
  } as unknown as PageClient;
  return { client, release: () => release() };
}

const mounted = (host: HTMLElement) => [...host.querySelectorAll<HTMLElement>(".clj-section:not(.clj-span)")];
const datesOf = (sections: HTMLElement[]) => sections.map((s) => s.querySelector("time")!.getAttribute("dateTime")!);

async function scrollWindow(y: number) {
  Object.defineProperty(dom.window, "scrollY", { configurable: true, value: y });
  await act(async () => void dom.window.dispatchEvent(new dom.window.Event("scroll")));
  await settle();
}

describe.each(["sheet", "journal"] as const)("the %s page's days", (design) => {
  const counts = new Map<number, { days: number; reads: number }>();

  for (const count of SIZES)
    test(`at ${count} builds it draws a screen of days, redraws only the day whose note loads, and a scroll reads no day's box`, async () => {
      const { ChangelogStore } = await import("../src/pages/changelog/store");
      const { ChangelogPage } = await import("../src/pages/changelog/ChangelogPage");
      const builds = index(count);
      const held = builds[1]!;
      const { client, release } = host(builds, held.build);
      const store = new ChangelogStore(client);
      await store.start();
      Object.defineProperty(dom.window, "scrollY", { configurable: true, value: 0 });
      const page = await mount(<ChangelogPage store={store} strings={await strings()} design={design} />);

      // A screen of days (768 px of 300 px days) and a few either side, never the index.
      const days = mounted(page);
      expect(days.length).toBeGreaterThan(1);
      expect(days.length).toBeLessThanOrEqual(12);
      expect(datesOf(days)[0]).toBe(builds[0]!.date);

      // One note loads: its day redraws, no other.
      dayDraws.clear();
      release();
      await settle();
      expect(dayDraws.get(held.date) ?? 0).toBeGreaterThan(0);
      expect([...dayDraws.keys()].filter((date) => date !== held.date)).toEqual([]);

      // One scroll step (a day): the days still drawn are not drawn again, and no day's box is read
      // for each of the index's days.
      const before = new Set(datesOf(mounted(page)));
      dayDraws.clear();
      boxReads = 0;
      await scrollWindow(DAY);
      const reads = boxReads;
      const after = mounted(page);
      expect(after.length).toBeLessThanOrEqual(12);
      const kept = datesOf(after).filter((date) => before.has(date));
      expect(kept.length).toBeGreaterThan(0);
      expect(kept.filter((date) => dayDraws.has(date))).toEqual([]);
      expect(reads).toBeLessThan(40);
      counts.set(count, { days: days.length, reads });
      await scrollWindow(0);
    }, 60_000);

  test("the days drawn and the boxes read do not grow with the index", () => {
    const small = counts.get(SIZES[0])!;
    const large = counts.get(SIZES[1])!;
    expect(Math.abs(large.days - small.days)).toBeLessThanOrEqual(Math.ceil(small.days * 0.1));
    expect(large.reads).toBeLessThanOrEqual(small.reads + Math.ceil(small.reads * 0.1));
  });
});

/** The update's changes: `count` of them, New, Improved and Fixed in turn, each with a detail. */
function update(count: number, changed?: number): UpdateHighlights {
  const kinds = ["new", "improved", "fixed"] as const;
  const items = Array.from({ length: count }, (_, i) => ({
    id: `c${i}`,
    title: `Tabs keep their place after change ${i}`,
    summary: i === changed ? `The detail of change ${i}, now longer.` : `The detail of change ${i}.`,
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
    moreCount: count - 3,
    changelog: { from: "1.0.0-nightly.4000000000000", to: "1.0.0-nightly.5000000000000" },
  };
}

describe.each(["release", "flat"] as const)("the Updated card's %s list", (look) => {
  const counts = new Map<number, { rows: number; reads: number }>();
  // The release look's three kinds each start their list where jsdom puts every box (0): each
  // draws its own screen of rows. The flat look is one list.
  const bound = look === "flat" ? 45 : 3 * 45;

  for (const count of SIZES)
    test(`at ${count} changes it draws a screen of rows, redraws only a changed one, and a scroll reads no row's box`, async () => {
      const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
      const text = await strings();
      const actions = { openChangelog: () => {} };
      const draw = (data: UpdateHighlights) => (
        <UpdatedNotes data={data} strings={text} actions={actions} mode="beside" look={look} />
      );
      const card = await mount(draw(update(count)));
      const rows = () => [...card.querySelectorAll(".wn-notes-row")];
      // Each drawn row's entry id, from its detail ("The detail of change 12.").
      const ids = () => rows().map((row) => `c${/change (\d+)/.exec(row.textContent ?? "")?.[1]}`);
      expect(rows().length).toBeGreaterThan(5);
      expect(rows().length).toBeLessThanOrEqual(bound);
      // The count below still counts every change past the scroller's edge, drawn or not.
      const more = card.querySelector(".wn-notes-more")?.textContent ?? "";
      expect(Number(/\d+/.exec(more)?.[0])).toBeGreaterThan(count - bound);

      // One change's detail changes: its row redraws, no other.
      rowDraws.clear();
      await act(async () => root!.render(draw(update(count, 0))));
      await settle();
      expect(rowDraws.get("c0") ?? 0).toBeGreaterThan(0);
      expect([...rowDraws.keys()].filter((id) => id !== "c0")).toEqual([]);

      // One scroll step (a row): the rows still drawn are not drawn again, and no row's box is read.
      const scroller = card.querySelector<HTMLElement>(".wn-notes")!;
      const before = new Set(ids());
      rowDraws.clear();
      boxReads = 0;
      Object.defineProperty(scroller, "scrollTop", { configurable: true, value: ROW });
      await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
      await settle();
      const reads = boxReads;
      expect(rows().length).toBeLessThanOrEqual(bound);
      expect(reads).toBeLessThan(20);
      const kept = ids().filter((id) => before.has(id));
      expect(kept.length).toBeGreaterThan(0);
      expect(kept.filter((id) => rowDraws.has(id))).toEqual([]);
      counts.set(count, { rows: rows().length, reads });
    }, 60_000);

  test("the rows drawn and the boxes read do not grow with the list", () => {
    const small = counts.get(SIZES[0])!;
    const large = counts.get(SIZES[1])!;
    expect(Math.abs(large.rows - small.rows)).toBeLessThanOrEqual(Math.ceil(small.rows * 0.1));
    expect(large.reads).toBeLessThanOrEqual(small.reads + Math.ceil(small.reads * 0.1));
  });
});
