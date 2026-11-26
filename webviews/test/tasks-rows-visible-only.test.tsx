// The Tasks page's rows render only when their own data changes (list, inbox and board, each under
// VirtualList): one task changed by another writer renders its one row; a selection change renders
// the row it left and the row it reached; a scroll step renders only the rows that enter the window;
// a re-render of the page with the same data renders none. Also how many rows are in the DOM at
// 1,000 and 10,000 tasks (jsdom, an 800 px viewport).
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, afterEach, beforeAll, expect, test, jest } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
const VIEWPORT = 800;

beforeAll(() => {
  // One fake clock for the whole file: the store's replies, the virtualizer's scroll-end reset and
  // the icon asks run when `advance` moves it, never on the wall clock.
  jest.useFakeTimers();
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/tasks/",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  // A viewport for the virtualizer: every box is the 800 px scroller, a board card 96 px tall.
  window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const height = this.classList.contains("tasks-card-slot") ? 96 : VIEWPORT;
    return { x: 0, y: 0, top: 0, left: 0, right: 600, bottom: height, width: 600, height, toJSON() {} } as DOMRect;
  };
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => VIEWPORT });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
  const offsets = new WeakMap<object, number>();
  Object.defineProperty(window.HTMLElement.prototype, "scrollTop", {
    configurable: true,
    get(this: object) {
      return offsets.get(this) ?? 0;
    },
    set(this: object, value: number) {
      offsets.set(this, value);
    },
  });
  window.HTMLElement.prototype.scrollIntoView = () => undefined;
  // The virtualizer sets its timers on the element's window: they run on the same fake clock.
  Object.assign(window, {
    setTimeout: (callback: () => void, ms?: number) => setTimeout(callback, ms),
    clearTimeout: (handle: Parameters<typeof clearTimeout>[0]) => clearTimeout(handle),
  });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { scope });
});

const { TasksPage } = await import("../src/pages/tasks/TasksPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/tasks/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockTasksProvider, sampleSnapshot } = await import("../src/pages/tasks/mockProvider");
const { TasksStore } = await import("../src/pages/tasks/store");
const { TasksOps } = await import("../src/pages/tasks/types");
type Layout = import("../src/pages/tasks/types").Layout;

/** Moves the fake clock `ms` forward in 10 ms steps, each in its own act(), so each step's
 * timers, the replies they unblock and the renders they cause all land before the next. */
async function advance(ms: number) {
  for (let step = 0; step < ms; step += 10) await act(async () => void jest.advanceTimersByTime(10));
}

/** `count` tasks, all in Todo (one list group, one board column), assignees as the sample's. */
function snapshotOf(count: number) {
  const sample = sampleSnapshot();
  const tasks = Array.from({ length: count }, (_, index) => ({
    ...sample.tasks[index % sample.tasks.length]!,
    id: `task_${index + 1}`,
    number: index + 1,
    title: `Task ${index + 1}`,
    status: "st_todo",
    attention: null,
    sort_key: String(index + 1).padStart(6, "0"),
  }));
  return { ...sample, tasks, settings: { ...sample.settings, next_number: count + 1 } };
}

type Fixture = ReturnType<typeof snapshotOf>;

async function mount(layout: Layout, count = 200, tweak?: (snapshot: Fixture) => void) {
  const fixture = snapshotOf(count);
  tweak?.(fixture);
  const provider = new MockTasksProvider(fixture);
  let key = 0;
  const store = new TasksStore(provider, { newKey: () => `k${++key}`, schedule: () => () => {}, visible: () => true });
  store.subscribe(() => {});
  await store.start();
  await advance(10);
  const strings = createStrings(table, ["en"]);
  const page = () => (
    <UiProvider container={host} dir="ltr">
      <TasksPage store={store} strings={strings} layout={layout} />
    </UiProvider>
  );
  root = createRoot(host);
  await act(async () => {
    root!.render(page());
  });
  await advance(20);
  return { provider, store, rerender: () => act(async () => root!.render(page())) };
}

/** Runs `change` and lets the store, the virtualizer and its scroll-end timer settle, then reads. */
async function counted(name: string, change: () => unknown): Promise<number> {
  rowRenders.reset();
  await act(async () => {
    await change();
  });
  await advance(200);
  return rowRenders.count(name);
}

const shownTasks = (selector: string) =>
  new Set([...host.querySelectorAll<HTMLElement>(selector)].map((row) => row.dataset.task!));

test("list: a task another writer changed renders its one row", async () => {
  const { provider } = await mount("list");
  expect(shownTasks(".tasks-row").has("task_3")).toBe(true);
  const renders = await counted("TaskRow", () =>
    provider.call(TasksOps.update, { task: "task_3", assignee: "usr_austin", idempotency_key: "cli-1" }),
  );
  expect(renders).toBe(1);
});

test("list: a status event re-renders only the rows of the tasks it changes", async () => {
  // task_3 alone in Backlog, which lists before Todo: its row is in the window.
  const { provider } = await mount("list", 200, (snapshot) => {
    snapshot.tasks[2]!.status = "st_backlog";
  });
  expect(shownTasks(".tasks-row").has("task_3")).toBe(true);
  const status = (id: string) => provider.state.statuses.find((candidate) => candidate.id === id)!;
  const send = (value: ReturnType<typeof status>) => {
    provider.state.seq += 1;
    provider.publish({
      change: {
        seq: provider.state.seq,
        index: 0,
        tx: `elsewhere-${provider.state.seq}`,
        kind: "status.updated",
        change: { type: "upsert", value: { entity: "status", ...value } },
      },
    });
  };
  // A status no task has is renamed: no row renders (each mounted menu takes the new name).
  expect(await counted("TaskRow", () => send({ ...status("st_done"), name: "Shipped" }))).toBe(0);
  // Backlog's category changes (its place holds): the one task in it renders.
  expect(await counted("TaskRow", () => send({ ...status("st_backlog"), category: "triage" }))).toBe(1);
});

/** An owner event from another writer: one entity upserted, at the next sequence. */
function publishUpsert(provider: InstanceType<typeof MockTasksProvider>, value: Record<string, unknown>) {
  provider.state.seq += 1;
  provider.publish({
    change: {
      seq: provider.state.seq,
      index: 0,
      tx: `elsewhere-${provider.state.seq}`,
      kind: `${String(value.entity)}.updated`,
      change: { type: "upsert", value } as never,
    },
  });
}

// 1,000 tasks wearing the sample's labels in turn; `lbl_solo` worn by task_3 alone, `lbl_unused` by none.
for (const [layout, row, selector] of [
  ["list", "TaskRow", ".tasks-row"],
  ["board", "BoardCard", ".tasks-card"],
] as const) {
  test(`${layout}: a label event redraws only the rows wearing that label (1,000 tasks)`, async () => {
    const { provider } = await mount(layout, 1_000, (snapshot) => {
      snapshot.labels.push({ id: "lbl_solo", name: "solo", color: 6 }, { id: "lbl_unused", name: "unused", color: 2 });
      snapshot.tasks[2]!.labels = ["lbl_solo"];
    });
    expect(shownTasks(selector).has("task_3")).toBe(true);
    const label = (id: string) => provider.state.labels.find((candidate) => candidate.id === id)!;
    // A label no task wears is renamed, and a new one arrives: no row redraws.
    expect(
      await counted(row, () => publishUpsert(provider, { entity: "label", ...label("lbl_unused"), name: "spare" })),
    ).toBe(0);
    expect(
      await counted(row, () => publishUpsert(provider, { entity: "label", id: "lbl_new", name: "new", color: 4 })),
    ).toBe(0);
    // task_3's own label is renamed, recoloured, then removed: its row alone redraws each time.
    expect(
      await counted(row, () => publishUpsert(provider, { entity: "label", ...label("lbl_solo"), name: "single" })),
    ).toBe(1);
    expect(await counted(row, () => publishUpsert(provider, { entity: "label", ...label("lbl_solo"), color: 1 }))).toBe(
      1,
    );
    expect(
      await counted(row, () => publishUpsert(provider, { entity: "label", ...label("lbl_solo"), archived: true })),
    ).toBe(1);
  });
}

// The inbox orders by priority then `updated_at`, so a changed task moves and its neighbours shift
// with it: its one-item case is the list's (the same TaskRow); here, selection and re-render.
for (const layout of ["list", "inbox"] as const) {
  test(`${layout}: a selection change renders the row it left and the row it reached`, async () => {
    const { store } = await mount(layout);
    const [, first, , , second] = [...shownTasks(".tasks-row")];
    await act(async () => store.select(first));
    expect(await counted("TaskRow", () => store.select(second))).toBe(2);
  });

  test(`${layout}: a re-render of the page with the same data renders no row`, async () => {
    const { rerender } = await mount(layout);
    rowRenders.reset();
    await rerender();
    expect(rowRenders.count("TaskRow")).toBe(0);
  });
}

test("list: one scroll step renders only the rows that enter the window", async () => {
  await mount("list");
  const scroller = host.querySelector<HTMLElement>(".tasks-list")!;
  const before = shownTasks(".tasks-row");
  const renders = await counted("TaskRow", () => {
    scroller.scrollTop = 28;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
  });
  const entered = [...shownTasks(".tasks-row")].filter((id) => !before.has(id));
  expect(entered.length).toBeGreaterThan(0);
  expect(renders).toBe(entered.length);
});

test("board: a task another writer changed renders its one card", async () => {
  const { provider } = await mount("board");
  expect(shownTasks(".tasks-card").has("task_3")).toBe(true);
  expect(
    await counted("BoardCard", () =>
      provider.call(TasksOps.update, { task: "task_3", assignee: "usr_austin", idempotency_key: "cli-1" }),
    ),
  ).toBe(1);
});

test("board: a selection change renders the card it left and the card it reached", async () => {
  const { store } = await mount("board");
  await act(async () => store.select("task_2"));
  expect(await counted("BoardCard", () => store.select("task_4"))).toBe(2);
});

test("board: a re-render of the page with the same data renders no card", async () => {
  const { rerender } = await mount("board");
  rowRenders.reset();
  await rerender();
  expect(rowRenders.count("BoardCard")).toBe(0);
});

test("list: rows in the DOM stay the window's at 1,000 and 10,000 tasks", async () => {
  const report: Record<number, { rows: number; nodes: number }> = {};
  for (const count of [1_000, 10_000]) {
    await mount("list", count);
    report[count] = {
      rows: host.querySelectorAll(".tasks-row").length,
      nodes: host.querySelectorAll("*").length,
    };
    act(() => root?.unmount());
    root = undefined;
  }
  console.log("tasks list mounted (jsdom, 800 px):", JSON.stringify(report));
  expect(report[10_000]!.rows).toBe(report[1_000]!.rows);
  expect(report[1_000]!.rows).toBeLessThan(60);
});
