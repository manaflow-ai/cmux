// HIDDEN-REBUILD: a hidden chat page that grew live hands its state over and reloads (hiddenRebuild.ts).
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { SWAP_HANDOFF_KEY } from "../../pages/shared/swapHandoff";
import {
  type HiddenRebuildTimers,
  installHiddenRebuild,
  LAST_REBUILD_KEY,
  noteWireFrame,
  resetHiddenRebuild,
} from "./hiddenRebuild";

const page = (body = "") => {
  const view = new JSDOM(`<!doctype html><head></head><body>${body}</body>`, {
    url: "http://cmux-page.localhost/agent/index.html",
    pretendToBeVisual: true,
  }).window as unknown as Window;
  let state: DocumentVisibilityState = "visible";
  Object.defineProperty(view.document, "visibilityState", { configurable: true, get: () => state });
  const hide = (hidden: boolean) => {
    state = hidden ? "hidden" : "visible";
    view.document.dispatchEvent(new (view as unknown as typeof globalThis).Event("visibilitychange"));
  };
  return { view, hide };
};

// Timers driven by hand: `run()` fires every one due, as the page's clock passing its delay would.
const manual = () => {
  let next = 1;
  const due = new Map<number, () => void>();
  const timers: HiddenRebuildTimers = {
    set: (run) => {
      due.set(next, run);
      return next++;
    },
    clear: (id) => void due.delete(id),
  };
  const run = () => {
    const now = [...due.values()];
    due.clear();
    for (const fire of now) fire();
  };
  return { timers, run };
};
const grow = (n: number) => {
  for (let i = 0; i < n; i++) noteWireFrame();
};

afterEach(() => resetHiddenRebuild());

test("a hidden page that grew rebuilds once, handing its state over", () => {
  const { view, hide } = page();
  const clock = manual();
  let reloads = 0;
  const stop = installHiddenRebuild(view.document, {
    grownFrames: 10,
    hiddenMs: 5,
    recheckMs: 5,
    reload: () => reloads++,
    timers: clock.timers,
  });
  grow(10);
  hide(true);
  clock.run();
  expect(reloads).toBe(1);
  expect(view.sessionStorage.getItem(SWAP_HANDOFF_KEY)).not.toBeNull();
  expect(Number(view.sessionStorage.getItem(LAST_REBUILD_KEY))).toBeGreaterThan(0);
  // The next look is within the gap: no second rebuild.
  hide(false);
  hide(true);
  clock.run();
  expect(reloads).toBe(1);
  stop();
});

test("a small page, a shown page, and one that holds an edit keep their document", () => {
  const small = page();
  const clock = manual();
  let reloads = 0;
  const reload = () => reloads++;
  const stopSmall = installHiddenRebuild(small.view.document, {
    grownFrames: 10,
    hiddenMs: 5,
    recheckMs: 5,
    reload,
    timers: clock.timers,
  });
  grow(5);
  small.hide(true);
  clock.run();
  expect(reloads).toBe(0);
  stopSmall();

  const shown = page();
  const stopShown = installHiddenRebuild(shown.view.document, {
    grownFrames: 1,
    hiddenMs: 5,
    recheckMs: 5,
    reload,
    timers: clock.timers,
  });
  shown.hide(true);
  shown.hide(false);
  clock.run();
  expect(reloads).toBe(0);
  stopShown();

  const edited = page(`<input value="half typed">`);
  const stopEdited = installHiddenRebuild(edited.view.document, {
    grownFrames: 1,
    hiddenMs: 5,
    recheckMs: 5,
    reload,
    timers: clock.timers,
  });
  edited.hide(true);
  clock.run();
  expect(reloads).toBe(0);
  // The edit goes: the next look rebuilds.
  (edited.view.document.querySelector("input") as HTMLInputElement).value = "";
  (edited.view.document.querySelector("input") as HTMLInputElement).defaultValue = "";
  clock.run();
  expect(reloads).toBe(1);
  stopEdited();
});
