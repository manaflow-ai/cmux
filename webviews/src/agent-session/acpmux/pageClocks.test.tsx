// The agent page's clocks rest while the page is hidden (MQ4 batch A): the running
// turn's activity line, "Working for", the subagents' clock and the sign-in wait make no call while
// hidden, and after the page shows again each reads what a page that never hid would read. Chrome
// throttles a hidden page's timers (third_party/blink/renderer/platform/scheduler/main_thread/
// page_scheduler_impl.cc); a page of ours stops them (ui/pageClock.ts, pages/shared/pageLifecycle.ts).
// The elapsed labels read the page's one clock: every label on the page shares one
// timer, and a label past a minute ticks once a minute (ui/useElapsedNow.ts).
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { pageLifecycleFor } from "../../pages/shared/pageLifecycle";
import { fixedPageClock } from "../../ui/fixedPageClock";
import { PageClock } from "../../ui/pageClock";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "./modelCatalogData";
import { HarnessesScreen } from "./harnesses/HarnessesScreen";
import { useNow } from "./subagents/SubagentGroup";
import { ActivityLine } from "./conversation/ActivityLine";
import { WorkingFor } from "./conversation/WorkingFor";

let dom: JSDOM | undefined;
let root: Root | undefined;
let visibility: DocumentVisibilityState = "visible";
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
  Object.defineProperty(dom.window.document, "hidden", { configurable: true, get: () => visibility === "hidden" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => {
  visibility = "visible";
  jest.useFakeTimers();
  jest.setSystemTime(1_000_000);
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

async function render(container: HTMLElement, element: React.ReactElement): Promise<HTMLElement> {
  await act(async () => {
    root = createRoot(container);
    root.render(element);
  });
  return container;
}

async function mount(element: React.ReactElement): Promise<HTMLElement> {
  return render(installDom(), element);
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

/// The page's clock on a time the test moves, its timeouts on the fake timers, counting the reads:
/// a read while hidden is a timer that ran. Made after installDom, on that page's lifecycle.
function testClock(start: number) {
  const clock = { time: start, reads: 0 };
  const page = new PageClock(pageLifecycleFor(), {
    now: () => (clock.reads++, clock.time),
    after: (ms, callback) => setTimeout(callback, ms),
    cancel: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  });
  return Object.assign(clock, { page });
}

const row = (fields: Partial<AcpmuxRow>) =>
  ({ id: "working-1", version: 1, at: 0, kind: "working", ...fields }) as AcpmuxRow;

test("the activity line reads no time while hidden and shows the same text as a fresh line on resume", async () => {
  const container = installDom();
  const clock = testClock(5_000);
  const line = row({ text: "Edit grid.css" });
  await render(container, <ActivityLine row={line} clock={clock.page} />);
  await advance(1000);
  clock.time += 1000;
  await advance(1000);
  expect(container.textContent).toContain("Edit grid.css");
  await setVisibility("hidden");
  const readsWhenHidden = clock.reads;
  clock.time += 90_000;
  await advance(90_000);
  expect(clock.reads).toBe(readsWhenHidden);
  await setVisibility("visible");
  const fresh = renderToStaticMarkup(<ActivityLine row={line} clock={fixedPageClock(clock.time)} />);
  expect(container.innerHTML).toBe(fresh);
});

test("Working for rests while hidden and catches up on show", async () => {
  const container = installDom();
  const clock = testClock(2_000);
  const line = row({});
  await render(container, <WorkingFor row={line} clock={clock.page} />);
  await setVisibility("hidden");
  const readsWhenHidden = clock.reads;
  clock.time = 185_000;
  await advance(60_000);
  expect(clock.reads).toBe(readsWhenHidden);
  await setVisibility("visible");
  const fresh = renderToStaticMarkup(<WorkingFor row={line} clock={fixedPageClock(clock.time)} />);
  expect(container.innerHTML).toBe(fresh);
  expect(container.textContent).toContain("3m");
  // Visible again and past a minute, it ticks on the minute, not each second.
  const readsWhenShown = clock.reads;
  clock.time = 186_000;
  await advance(1000);
  expect(clock.reads).toBe(readsWhenShown);
  clock.time = 240_000;
  await advance(54_000);
  expect(clock.reads).toBeGreaterThan(readsWhenShown);
  expect(container.textContent).toContain("4m");
});

test("every running label on the page shares one timer: a second one under a minute, a minute one after", async () => {
  const container = installDom();
  const clock = testClock(30_000);
  const lines = [row({ id: "a", at: 0 }), row({ id: "b", at: 10_000 }), row({ id: "c", at: 25_000 })];
  await render(
    container,
    <>
      {lines.map((line) => (
        <WorkingFor key={line.id} row={line} clock={clock.page} />
      ))}
      <ActivityLine row={row({ id: "d", text: "Edit grid.css", at: 5_000 })} clock={clock.page} />
    </>,
  );
  expect(jest.getTimerCount()).toBe(1);
  // Every label steps on the same second.
  clock.time = 31_000;
  await advance(1000);
  expect(container.textContent).toContain("31s");
  expect(container.textContent).toContain("21s");
  expect(container.textContent).toContain("6s");
  expect(jest.getTimerCount()).toBe(1);
  // From the minute boundary a minute past every start, every label is on the minute clock.
  clock.time = 120_000;
  await advance(89_000);
  expect(jest.getTimerCount()).toBe(1);
  expect(container.textContent).toContain("2m");
  expect(container.textContent).toContain("1m");
  expect(container.textContent).not.toMatch(/\d+s/);
  const readsOnMinute = clock.reads;
  clock.time = 150_000;
  await advance(30_000);
  expect(clock.reads).toBe(readsOnMinute);
});

test("a label that passes a minute shows whole minutes and never steps back", async () => {
  const container = installDom();
  const clock = testClock(59_000);
  const line = row({ text: "Edit grid.css", at: 30_500 });
  await render(container, <ActivityLine row={line} clock={clock.page} />);
  const shown: string[] = [];
  for (let time = 60_000; time <= 181_000; time += 1000) {
    clock.time = time;
    await advance(1000);
    shown.push(container.querySelector(".cv-activity__time")!.textContent!);
  }
  const seconds = shown.map((label) => Number.parseInt(label, 10) * (label.endsWith("m") ? 60 : 1));
  for (let index = 1; index < seconds.length; index++)
    expect(seconds[index]!).toBeGreaterThanOrEqual(seconds[index - 1]!);
  expect(shown).toContain("29s");
  expect(shown).toContain("1m");
  expect(shown).toContain("2m");
  expect(shown.some((label) => / \d+s/.test(label))).toBe(false);
});

function NowProbe({ live, renders }: { live: boolean; renders: { count: number } }) {
  const now = useNow(live);
  renders.count++;
  return <output>{now}</output>;
}

test("the subagents' clock makes no render while hidden and reads the time on show", async () => {
  const renders = { count: 0 };
  const container = await mount(<NowProbe live renders={renders} />);
  await advance(1000);
  expect(container.textContent).toBe(String(Date.now()));
  await setVisibility("hidden");
  const rendersWhenHidden = renders.count;
  await advance(60_000);
  expect(renders.count).toBe(rendersWhenHidden);
  await setVisibility("visible");
  expect(container.textContent).toBe(String(Date.now()));
});

const thisMac: AcpmuxSnapshot["catalog"] = [
  { id: "codex", name: "Codex", family: "codex", models: [], auth: { login: "codex login" } },
];

/// The Harnesses page waiting for a Codex sign-in it started, every `harness.health` refresh it
/// asks for recorded in `refreshes`.
async function waitingForSignIn(refreshes: string[]): Promise<HTMLElement> {
  const native = (method: string, params: Record<string, unknown> = {}) => {
    if (method === "harness.health") {
      if (params.refresh) refreshes.push(String(params.id));
      return Promise.resolve({ health: { id: params.id, auth: "signedOut" } });
    }
    return Promise.resolve({});
  };
  const container = await mount(
    <HarnessesScreen
      catalog={buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: thisMac })}
      acpmux={thisMac}
      callNative={native}
      onClose={() => undefined}
      signInPollMs={1000}
    />,
  );
  await act(async () => undefined);
  const button = container.querySelector<HTMLButtonElement>('[data-harness-status="signIn"] button');
  expect(button).not.toBeNull();
  await act(async () => button!.click());
  expect(container.querySelector('[data-harness-status="waiting"]')).not.toBeNull();
  return container;
}

test("a sign-in wait checks nothing while hidden or on show, and checks one period after show", async () => {
  const refreshes: string[] = [];
  await waitingForSignIn(refreshes);
  await advance(1000);
  expect(refreshes).toEqual(["codex"]);
  await setVisibility("hidden");
  await advance(30_000);
  expect(refreshes).toEqual(["codex"]);
  // Showing the page is no read: the check waits for its next period.
  await setVisibility("visible");
  await act(async () => undefined);
  expect(refreshes).toEqual(["codex"]);
  await advance(1000);
  expect(refreshes).toEqual(["codex", "codex"]);
});

test("a sign-in wait that ended while hidden clears on the first tick after show, with no check", async () => {
  const refreshes: string[] = [];
  const container = await waitingForSignIn(refreshes);
  await setVisibility("hidden");
  await advance(4 * 60 * 1000);
  await setVisibility("visible");
  await act(async () => undefined);
  expect(container.querySelector('[data-harness-status="waiting"]')).not.toBeNull();
  await advance(1000);
  expect(refreshes).toEqual([]);
  expect(container.querySelector('[data-harness-status="waiting"]')).toBeNull();
  expect(container.querySelector('[data-harness-status="signIn"]')).not.toBeNull();
});
