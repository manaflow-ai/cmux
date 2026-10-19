// cmux-web-test-timeout: 600
// perf-10x settings bench (msg 1628). Skipped unless CMUX_SETTINGS_BENCH=1; the fleet runs it
// through scripts/measure/perf-10x-settings.sh. It drives the real page (store, query cache,
// every component) over the mock provider and reports, per scenario, the wall time from the
// gesture to the settled page, React's own render time (Profiler actualDuration), how many
// components rendered, and how many settings reads (cmux.settings.list) the gesture cost.
// Prints one `SETTINGS_BENCH {json}` line per scenario.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

type Fiber = {
  tag: number;
  type: unknown;
  child: Fiber | null;
  sibling: Fiber | null;
  memoizedProps: unknown;
  memoizedState: unknown;
};

// A DevTools hook installed before React DOM loads: each commit, count the function components
// whose props or hook state object is new (they rendered in that commit). Only on while counting,
// so the timed runs pay nothing for it.
const counter = { on: false, rendered: 0, rows: 0, seen: new WeakSet<object>() };
function walk(fiber: Fiber | null): void {
  for (let node = fiber; node; node = node.sibling) {
    if (node.tag === 0 || node.tag === 11 || node.tag === 15) {
      const props = node.memoizedProps as object | null;
      const state = node.memoizedState as object | null;
      const fresh = (props !== null && !counter.seen.has(props)) || (state !== null && !counter.seen.has(state));
      if (props) counter.seen.add(props);
      if (state) counter.seen.add(state);
      if (fresh) {
        counter.rendered += 1;
        if ((node.type as { name?: string } | null)?.name === "SettingRow") counter.rows += 1;
      }
    }
    walk(node.child);
  }
}
(globalThis as Record<string, unknown>).__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
  isDisabled: false,
  supportsFiber: true,
  renderers: new Map(),
  inject: () => 1,
  checkDCE: () => {},
  onScheduleFiberRoot: () => {},
  onCommitFiberUnmount: () => {},
  onPostCommitFiberRoot: () => {},
  onCommitFiberRoot: (_id: number, root: { current: Fiber }) => {
    if (counter.on) walk(root.current);
  },
};

// The scratch bench branch flips this default (the fleet step takes no env).
const enabled = process.env.CMUX_SETTINGS_BENCH === "1";
const iterations = Number(process.env.CMUX_SETTINGS_BENCH_N ?? 40);

const restore = installDom();
afterAll(() => restore());
const { act, Profiler, createElement } = await import("react");
const { createMemoryHistory } = await import("@tanstack/react-router");
const { settle } = await import("./testing");
const { SettingsPage } = await import("./components/SettingsPage");
const { createMockClient } = await import("./mockProvider");
const { SettingsStore } = await import("./store");
const { setLocale } = await import("./strings");
const { homes } = await import("./categories");
const { THEME_KEY } = await import("./components/ThemeStudio");
// The same fresh React DOM copy testing.tsx loads (it sees the jsdom and the hook above).
const { fileURLToPath } = await import("node:url");
const clientPath = fileURLToPath(
  new URL(
    `./cjs/react-dom-client.${process.env.NODE_ENV === "production" ? "production" : "development"}.js`,
    import.meta.resolve("react-dom/client"),
  ),
);
const { createRoot } = require(clientPath) as typeof import("react-dom/client");

type Page = {
  container: HTMLElement;
  store: InstanceType<typeof SettingsStore>;
  lists(): number;
  reactMs(): number;
  unmount(): void;
};

let renderMs = 0;
async function mount(path: string): Promise<Page> {
  setLocale("en");
  const mock = createMockClient();
  const store = new SettingsStore(mock.client);
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => {
    await store.start();
    const history = createMemoryHistory({ initialEntries: [path] });
    root.render(
      createElement(
        Profiler,
        { id: "settings", onRender: (_id: string, _phase: string, actual: number) => (renderMs += actual) },
        createElement(SettingsPage, { store, history }),
      ),
    );
  });
  await settle();
  return {
    container,
    store,
    lists: () => mock.provider.log.filter((entry) => entry.op === "cmux.settings.list").length,
    reactMs: () => renderMs,
    unmount() {
      act(() => root.unmount());
      container.remove();
      store.dispose();
      mock.close();
    },
  };
}

type Sample = { wall: number; react: number; rendered: number; rows: number; lists: number };

function stats(name: string, samples: Sample[]) {
  const pick = (field: keyof Sample) => {
    const sorted = samples.map((sample) => sample[field]).sort((a, b) => a - b);
    const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
    return { p50: +at(0.5).toFixed(2), p95: +at(0.95).toFixed(2), max: +sorted.at(-1)!.toFixed(2) };
  };
  const out = {
    scenario: name,
    n: samples.length,
    wallMs: pick("wall"),
    reactMs: pick("react"),
    componentsRendered: pick("rendered"),
    settingRowsRendered: pick("rows"),
    settingsListReads: pick("lists"),
  };
  // A notice line: run-webviews-tests.sh shows a passing file's notices.
  console.log(`::notice::SETTINGS_BENCH ${JSON.stringify(out)}`);
  return out;
}

/** Times `gesture` (its act plus the settle that drains the owner's replies) on `page`. */
async function measure(page: Page, gesture: () => void | Promise<void>, count: boolean): Promise<Sample> {
  const listsBefore = page.lists();
  const reactBefore = page.reactMs();
  counter.rendered = 0;
  counter.rows = 0;
  counter.on = count;
  const start = performance.now();
  await act(async () => {
    await gesture();
  });
  await settle();
  const wall = performance.now() - start;
  counter.on = false;
  return {
    wall,
    react: page.reactMs() - reactBefore,
    rendered: counter.rendered,
    rows: counter.rows,
    lists: page.lists() - listsBefore,
  };
}

/** Each sample is timed once without counting, then (same gesture shape) counted separately. */
async function scenario(
  name: string,
  path: string,
  gesture: (page: Page, index: number) => void | Promise<void>,
): Promise<void> {
  const page = await mount(path);
  try {
    // Warm the counter's seen set with the mounted tree.
    counter.on = true;
    await measure(page, () => {}, true);
    const timed: Sample[] = [];
    const counted: Sample[] = [];
    for (let index = 0; index < iterations; index += 1) {
      timed.push(await measure(page, () => gesture(page, index * 2), false));
      counted.push(await measure(page, () => gesture(page, index * 2 + 1), true));
    }
    stats(
      name,
      timed.map((sample, index) => ({ ...sample, rendered: counted[index]!.rendered, rows: counted[index]!.rows })),
    );
  } finally {
    page.unmount();
  }
}

function setInput(element: HTMLInputElement, value: string): void {
  const proto = Object.getPrototypeOf(element) as object;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(element, value);
  element.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function sectionPath(key: string): string {
  return `/settings/${homes.get(key)!.category}`;
}

test.skipIf(!enabled)(
  "settings perf bench",
  async () => {
    // Cold open: a new store and page (start, first read, first render) per sample.
    for (const section of ["general", "appearance", "theme"]) {
      const samples: Sample[] = [];
      for (let index = 0; index < iterations; index += 1) {
        const before = renderMs;
        const start = performance.now();
        const page = await mount(`/settings/${section}`);
        samples.push({
          wall: performance.now() - start,
          react: renderMs - before,
          rendered: 0,
          rows: 0,
          lists: page.lists(),
        });
        expect(
          page.container.querySelector("[data-row-key]") ?? page.container.querySelector(".section"),
        ).not.toBeNull();
        page.unmount();
      }
      stats(`open.${section}`, samples);
    }

    // Search: one keystroke at a time through "font size", then clearing it.
    const query = "font size";
    await scenario("search.keystroke", "/settings/general", (page, index) => {
      const field = page.container.querySelector<HTMLInputElement>(".search-input")!;
      const step = index % (query.length + 1);
      setInput(field, step === query.length ? "" : query.slice(0, step + 1));
    });

    // A switch on the General page (59 rows): click, optimistic value, write, re-read.
    const toggleKey = "tabs.cmdWClosesPinnedTabs";
    await scenario("toggle.bool", sectionPath(toggleKey), (page) => {
      page.container.querySelector<HTMLButtonElement>(`[data-row-key="${toggleKey}"] [role="switch"]`)!.click();
    });

    // Font size on its page: the write the field commits.
    const fontKey = "terminal.fontSize";
    await scenario("set.fontSize", sectionPath(fontKey), async (page, index) => {
      await page.store.set(fontKey, 12 + (index % 6));
    });

    // Theme pick on the Theme page.
    const themes = ["Dracula", "Tokyo Night", "Gruvbox Dark", "Catppuccin Mocha"];
    await scenario("set.theme", "/settings/theme", async (page, index) => {
      await page.store.set(THEME_KEY, themes[index % themes.length]);
    });
  },
  600_000,
);
