// The Chief view gallery's minute stamps and the conversation's "Working for" clock run no timer
// while the page is hidden (MQ4 batch C). Chrome throttles a hidden page's timers
// (third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc); a page of
// ours stops them (usePageInterval, pages/shared/pageLifecycle.ts). Each clock reads the time again
// when the page shows, so its text is the one a page that never hid shows.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChiefViewsPage } from "./chief-views/ChiefViewsPage";
import { MockChiefViewsProvider } from "./chief-views/mockProvider";
import { CHIEF_VIEWS } from "./chief-views/registry";
import { ChiefViewsStore } from "./chief-views/store";
import { runLabel, useNow } from "./home-channels/RunCard";
import type { HomeRun } from "./home-channels/types";
import { createStrings } from "./shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
let visibility: DocumentVisibilityState = "visible";
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const START = 1_000_000;
const MINUTE = 60_000;
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "localStorage"] as const;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
  Object.defineProperty(dom.window.document, "hidden", { configurable: true, get: () => visibility === "hidden" });
  for (const key of [...KEYS, "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => {
  visibility = "visible";
  jest.useFakeTimers();
  jest.setSystemTime(START);
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function mount(element: ReactElement): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(element);
  });
  return container;
}

async function advance(ms: number) {
  await act(async () => {
    jest.advanceTimersByTime(ms);
  });
}

async function setVisibility(next: DocumentVisibilityState) {
  visibility = next;
  await act(async () => {
    document.dispatchEvent(new dom!.window.Event("visibilitychange"));
  });
}

const strings = createStrings({ en: { "run.label.running": "Working for %@" } }, ["en"]);
const run: HomeRun = {
  id: "run",
  conversation: "c",
  author: "chief",
  status: "running",
  startedAt: START,
  updatedAt: START,
  rev: 1,
  stepCount: 0,
  answers: [],
};

function RunClock({ running }: { running: boolean }) {
  const now = useNow(running);
  return <output>{runLabel(run, now, strings)}</output>;
}

test("the Working for clock rests while hidden and shows the true time again on show", async () => {
  const page = await mount(<RunClock running />);
  const label = () => page.querySelector("output")?.textContent;
  await advance(3_000);
  const visibleAt3s = label();

  await setVisibility("hidden");
  expect(jest.getTimerCount()).toBe(0);
  await advance(MINUTE);
  expect(label()).toBe(visibleAt3s);
  expect(jest.getTimerCount()).toBe(0);

  await setVisibility("visible");
  expect(label()).toBe(runLabel(run, START + 63_000, strings));
  expect(label()).not.toBe(visibleAt3s);
  await advance(1_000);
  expect(label()).toBe(runLabel(run, START + 64_000, strings));
});

test("a finished run's clock holds no timer, shown or hidden", async () => {
  await mount(<RunClock running={false} />);
  expect(jest.getTimerCount()).toBe(0);
  await setVisibility("hidden");
  await setVisibility("visible");
  expect(jest.getTimerCount()).toBe(0);
});

test("the Chief view gallery's minute tick rests while hidden and arms again on show", async () => {
  const store = new ChiefViewsStore(null, CHIEF_VIEWS, { persist: false });
  await mount(<ChiefViewsPage store={store} strings={createStrings({}, ["en"])} />);
  expect(jest.getTimerCount()).toBe(1);

  await setVisibility("hidden");
  expect(jest.getTimerCount()).toBe(0);
  await advance(10 * MINUTE);
  expect(jest.getTimerCount()).toBe(0);

  await setVisibility("visible");
  expect(jest.getTimerCount()).toBe(1);
});

test("the Chief view stamps read the true time on show, before any further tick", async () => {
  const chiefStrings = createStrings({}, ["en"]);
  const started = (now?: number) => {
    const store = new ChiefViewsStore(new MockChiefViewsProvider("busy", START), CHIEF_VIEWS, { persist: false });
    return { store, element: <ChiefViewsPage store={store} strings={chiefStrings} now={now} /> };
  };
  const live = started();
  const page = await mount(live.element);
  await act(async () => live.store.start());
  const stamps = (container: ParentNode) => [...container.querySelectorAll(".cv-ago")].map((node) => node.textContent);
  const before = stamps(page);
  expect(before.length).toBeGreaterThan(0);

  await setVisibility("hidden");
  await advance(10 * MINUTE);
  await setVisibility("visible");
  const shown = stamps(page);

  // A page that never hid, at the same instant.
  const reference = started(START + 10 * MINUTE);
  const other = document.createElement("div");
  document.body.append(other);
  const otherRoot = createRoot(other);
  await act(async () => otherRoot.render(reference.element));
  await act(async () => reference.store.start());
  expect(shown).toEqual(stamps(other));
  expect(shown).not.toEqual(before);
  await act(async () => otherRoot.unmount());
});

test("the Chief view gallery on a fixed clock (the gallery) holds no timer", async () => {
  const store = new ChiefViewsStore(null, CHIEF_VIEWS, { persist: false });
  await mount(<ChiefViewsPage store={store} strings={createStrings({}, ["en"])} now={START} />);
  expect(jest.getTimerCount()).toBe(0);
});
