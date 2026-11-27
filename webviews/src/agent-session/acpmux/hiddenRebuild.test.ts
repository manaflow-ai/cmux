// HIDDEN-REBUILD: a hidden chat page that grew live hands its state over and reloads (hiddenRebuild.ts).
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { SWAP_HANDOFF_KEY } from "../../pages/shared/swapHandoff";
import { installHiddenRebuild, LAST_REBUILD_KEY, noteWireFrame, resetHiddenRebuild } from "./hiddenRebuild";

const page = (body = "") => {
  const view = new JSDOM(`<!doctype html><head></head><body>${body}</body>`, {
    url: "http://cmux-page.localhost/agent/index.html",
    pretendToBeVisual: true,
  }).window as unknown as Window;
  let state: DocumentVisibilityState = "visible";
  Object.defineProperty(view.document, "visibilityState", { configurable: true, get: () => state });
  const hide = (hidden: boolean) => {
    state = hidden ? "hidden" : "visible";
    view.document.dispatchEvent(new view.Event("visibilitychange"));
  };
  return { view, hide };
};

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const grow = (n: number) => {
  for (let i = 0; i < n; i++) noteWireFrame();
};

afterEach(() => resetHiddenRebuild());

test("a hidden page that grew rebuilds once, handing its state over", async () => {
  const { view, hide } = page();
  let reloads = 0;
  const stop = installHiddenRebuild(view.document, {
    grownFrames: 10,
    hiddenMs: 5,
    recheckMs: 5,
    reload: () => reloads++,
  });
  grow(10);
  hide(true);
  await wait(30);
  expect(reloads).toBe(1);
  expect(view.sessionStorage.getItem(SWAP_HANDOFF_KEY)).not.toBeNull();
  expect(Number(view.sessionStorage.getItem(LAST_REBUILD_KEY))).toBeGreaterThan(0);
  // The next look is within the gap: no second rebuild.
  hide(false);
  hide(true);
  await wait(30);
  expect(reloads).toBe(1);
  stop();
});

test("a small page, a shown page, and one that holds an edit keep their document", async () => {
  const small = page();
  let reloads = 0;
  const reload = () => reloads++;
  const stopSmall = installHiddenRebuild(small.view.document, { grownFrames: 10, hiddenMs: 5, recheckMs: 5, reload });
  grow(5);
  small.hide(true);
  await wait(20);
  expect(reloads).toBe(0);
  stopSmall();

  const shown = page();
  const stopShown = installHiddenRebuild(shown.view.document, { grownFrames: 1, hiddenMs: 5, recheckMs: 5, reload });
  shown.hide(true);
  shown.hide(false);
  await wait(20);
  expect(reloads).toBe(0);
  stopShown();

  const edited = page(`<input value="half typed">`);
  const stopEdited = installHiddenRebuild(edited.view.document, { grownFrames: 1, hiddenMs: 5, recheckMs: 5, reload });
  edited.hide(true);
  await wait(20);
  expect(reloads).toBe(0);
  // The edit goes: the next look rebuilds.
  (edited.view.document.querySelector("input") as HTMLInputElement).value = "";
  (edited.view.document.querySelector("input") as HTMLInputElement).defaultValue = "";
  await wait(20);
  expect(reloads).toBe(1);
  stopEdited();
});
