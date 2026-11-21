/// <reference types="vite/client" />
// The team board's perf harness page (run.ts drives it). `window.boardHarness.mount(n, windowed)`
// mounts the shipped BoardPage over the mock host with a generated board of n machines and
// resolves once its rows are painted; `startUpdates(rate)` streams generated changes.
import { createRoot, type Root } from "react-dom/client";
import { flushSync } from "react-dom";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/board/generated/strings.json";
import { BoardPage } from "../../src/pages/board/BoardPage";
import { fixtureBoard, fixtureUpdates } from "../../src/pages/board/fixtures";
import { MockBoardProvider } from "../../src/pages/board/mockProvider";
import { BoardStore } from "../../src/pages/board/store";
import type { BoardSnapshot } from "../../src/pages/board/types";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/board/styles.css";

const machineCount = (board: BoardSnapshot | undefined) => board?.machines.length ?? 0;
const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

let root: Root | undefined;
let mounted: BoardStore | undefined;
let provider: MockBoardProvider | undefined;
let snapshot: BoardSnapshot | undefined;
let timer: ReturnType<typeof setInterval> | undefined;

declare global {
  interface Window {
    boardHarness: typeof harness;
  }
}

const harness = {
  /** Generates the board outside the measured span. */
  prepare(n: number, seed = 1) {
    snapshot = fixtureBoard({ machines: n, seed });
    provider = new MockBoardProvider({ snapshot });
  },
  /** Mounts the page and answers the ms from mount to the first painted frame with rows. */
  async mount(windowed: boolean): Promise<number> {
    const element = document.getElementById("root")!;
    const started = performance.now();
    const store = new BoardStore(provider!);
    mounted = store;
    root = createRoot(element);
    flushSync(() => root!.render(<BoardPage store={store} strings={createStrings(table)} windowed={windowed} />));
    await store.start();
    store.flush();
    while (machineCount(snapshot) > 0 && !document.querySelector(".board-row") && performance.now() - started < 60_000)
      await frame();
    await frame();
    return performance.now() - started;
  },
  rows(): number {
    return document.querySelectorAll(".board-row").length;
  },
  /** Scrolls the list `steps` times by `delta` px (wrapping at the end), one step per frame, and
   *  answers each frame's interval in ms. */
  async scroll(steps: number, delta: number): Promise<number[]> {
    const list = document.querySelector<HTMLElement>(".board-list")!;
    const intervals: number[] = [];
    let last = await frame();
    for (let step = 0; step < steps; step += 1) {
      const max = list.scrollHeight - list.clientHeight;
      list.scrollTop = max <= 0 ? 0 : (list.scrollTop + delta) % max;
      const now = await frame();
      intervals.push(now - last);
      last = now;
    }
    return intervals;
  },
  /** Streams `rate` generated changes a second, in 10 ms ticks, for `ms`, and answers each frame's interval. */
  async updates(rate: number, ms: number): Promise<number[]> {
    const events = fixtureUpdates(snapshot!, Math.ceil((rate * ms) / 1000) + 10, 5);
    let next = 0;
    const perTick = Math.max(1, Math.round(rate / 100));
    timer = setInterval(() => {
      for (let i = 0; i < perTick && next < events.length; i += 1) provider!.push(events[next++]!);
    }, 10);
    const intervals: number[] = [];
    const started = performance.now();
    let last = await frame();
    while (performance.now() - started < ms) {
      const now = await frame();
      intervals.push(now - last);
      last = now;
    }
    clearInterval(timer);
    return intervals;
  },
  unmount() {
    mounted?.stop();
    root?.unmount();
    root = undefined;
  },
};

window.boardHarness = harness;
