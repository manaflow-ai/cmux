// The agent page's clocks rest while the page is hidden (p13-webui-034, MQ4 batch A): the running
// turn's activity line, "Working for", the subagents' clock and the sign-in wait make no call while
// hidden, and after the page shows again each reads what a page that never hid would read. Chrome
// throttles a hidden page's timers (third_party/blink/renderer/platform/scheduler/main_thread/
// page_scheduler_impl.cc); a page of ours stops them (usePageInterval, pages/shared/pageLifecycle.ts).
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
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

async function mount(element: React.ReactElement): Promise<HTMLElement> {
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

/// A clock the test moves, counting the reads: a read is a timer callback that ran.
function testClock(start: number) {
  const clock = { time: start, reads: 0, now: () => (clock.reads++, clock.time) };
  return clock;
}

const row = (fields: Partial<AcpmuxRow>) =>
  ({ id: "working-1", version: 1, at: 0, kind: "working", ...fields }) as AcpmuxRow;

test("the activity line reads no time while hidden and shows the same text as a fresh line on resume", async () => {
  const clock = testClock(5_000);
  const line = row({ text: "Edit grid.css" });
  const container = await mount(<ActivityLine row={line} now={clock.now} />);
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
  const fresh = renderToStaticMarkup(<ActivityLine row={line} now={() => clock.time} />);
  expect(container.innerHTML).toBe(fresh);
});

test("Working for rests while hidden and catches up on show", async () => {
  const clock = testClock(2_000);
  const line = row({});
  const container = await mount(<WorkingFor row={line} now={clock.now} />);
  await setVisibility("hidden");
  const readsWhenHidden = clock.reads;
  clock.time = 185_000;
  await advance(60_000);
  expect(clock.reads).toBe(readsWhenHidden);
  await setVisibility("visible");
  const fresh = renderToStaticMarkup(<WorkingFor row={line} now={() => clock.time} />);
  expect(container.innerHTML).toBe(fresh);
  // Visible again, it ticks each second as before.
  const readsWhenShown = clock.reads;
  await advance(1000);
  expect(clock.reads).toBeGreaterThan(readsWhenShown);
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
