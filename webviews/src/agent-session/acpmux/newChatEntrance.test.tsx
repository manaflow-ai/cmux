// A new chat's entrance (newChatEntrance.ts) never stands between the person and the composer: it is
// typeable and focusable in the commit that mounts the hero, only transform, opacity and filter move,
// the motion holds at time zero until after the first frame renders, and Reduce Motion draws at rest.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { EmptyState } from "./EmptyState";
import {
  NEW_CHAT_PART_MS,
  NEW_CHAT_STAGGER_MS,
  resetNewChatEntranceClaims,
  type NewChatEntrance,
} from "./newChatEntrance";
import { settleReact } from "../../../test/support/domTeardown";

type FakeAnimation = {
  target: Element;
  keyframes: Keyframe[];
  options: KeyframeAnimationOptions;
  playState: AnimationPlayState;
  currentTime: number | null;
  pause(): void;
  play(): void;
  cancel(): void;
};

let dom: JSDOM | undefined;
let root: Root | undefined;
let animations: FakeAnimation[] = [];
let frames: (() => void)[] = [];
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom({ reduced = false } = {}): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const window = dom.window;
  animations = [];
  frames = [];
  (window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function (
    this: Element,
    keyframes: Keyframe[],
    options: KeyframeAnimationOptions,
  ) {
    const animation: FakeAnimation = {
      target: this,
      keyframes,
      options,
      playState: "running",
      currentTime: 0,
      pause: () => void (animation.playState = "paused"),
      play: () => void (animation.playState = "running"),
      cancel: () => void (animation.playState = "idle"),
    };
    animations.push(animation);
    return animation;
  };
  (window as unknown as { matchMedia: unknown }).matchMedia = (query: string) => ({
    matches: reduced && query.includes("prefers-reduced-motion: reduce"),
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    localStorage: window.localStorage,
    // The frame callback is driven by hand, so a test can look at the state before and after it.
    requestAnimationFrame: (run: () => void) => frames.push(run),
    cancelAnimationFrame: (handle: number) => void (frames[handle - 1] = () => {}),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return window.document.getElementById("root")!;
}

afterEach(async () => {
  resetNewChatEntranceClaims();
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/** A new chat as App.tsx lays it out: the hero over the dock's composer. */
function Pane({ entrance, hero = true, chat }: { entrance?: NewChatEntrance; hero?: boolean; chat?: string }) {
  return (
    <div className="acpmux-main" data-new-chat="">
      {hero && <EmptyState {...(entrance ? { entrance } : {})} {...(chat ? { entranceKey: chat } : {})} />}
      <div className="acpmux-dock">
        <div className="acpmux-composer">
          <textarea aria-label="Message" />
        </div>
      </div>
    </div>
  );
}

async function render(container: HTMLElement, element: React.ReactElement) {
  root ??= createRoot(container);
  await act(async () => root!.render(element));
}

const macrotask = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

function paintFrame() {
  const run = frames;
  frames = [];
  for (const callback of run) callback();
}

test("the composer takes focus and keys in the commit that mounts the hero, before any frame", async () => {
  const container = installDom();
  await render(container, <Pane />);
  // No frame has run: the entrance is held, and the composer is already usable.
  expect(frames.length).toBe(1);
  const composer = container.querySelector<HTMLElement>(".acpmux-composer")!;
  const field = container.querySelector("textarea")!;
  field.focus();
  expect(document.activeElement).toBe(field);
  field.value = "hi";
  field.dispatchEvent(new window.Event("input", { bubbles: true }));
  expect(field.value).toBe("hi");
  // Nothing blocks it: no inert, no pointer-events, no tab index games.
  for (const element of [composer, field]) {
    expect(element.hasAttribute("inert")).toBe(false);
    expect(element.style.pointerEvents).toBe("");
    expect(element.getAttribute("tabindex")).toBeNull();
  }
  // The composer moves, but is never drawn invisible.
  const composerMotion = animations.find((animation) => animation.target === composer)!;
  expect(composerMotion).toBeDefined();
  expect(Number(composerMotion.keyframes[0]!.opacity)).toBeGreaterThan(0);
});

test("the default rise moves only transform and opacity, staggered, at rest within 450 ms", async () => {
  const container = installDom();
  await render(container, <Pane />);
  expect(animations.length).toBeGreaterThanOrEqual(2);
  const end = Math.max(...animations.map((animation) => Number(animation.options.delay ?? 0) + NEW_CHAT_PART_MS));
  expect(end).toBeLessThanOrEqual(450);
  expect(animations[0]!.options.delay).toBe(0);
  expect(new Set(animations.map((animation) => animation.options.delay)).size).toBeGreaterThan(1);
  for (const animation of animations) expect(Number(animation.options.delay) % NEW_CHAT_STAGGER_MS).toBe(0);
  for (const animation of animations)
    for (const frame of animation.keyframes)
      for (const key of Object.keys(frame)) expect(["opacity", "transform", "offset"]).toContain(key);
});

test("the entrance holds at time zero through the first frame and plays from the task it posts", async () => {
  const container = installDom();
  await render(container, <Pane />);
  expect(animations.every((animation) => animation.playState === "paused" && animation.currentTime === 0)).toBe(true);
  paintFrame();
  // The frame callback runs before rendering: still held.
  expect(animations.every((animation) => animation.playState === "paused")).toBe(true);
  await macrotask();
  expect(animations.every((animation) => animation.playState === "running")).toBe(true);
});

test("sending the first message (the hero unmounts) cancels the entrance: the composer is at rest", async () => {
  const container = installDom();
  await render(container, <Pane />);
  await render(container, <Pane hero={false} />);
  expect(animations.every((animation) => animation.playState === "idle")).toBe(true);
  paintFrame();
  await macrotask();
  expect(animations.every((animation) => animation.playState === "idle")).toBe(true);
});

test("Reduce Motion: nothing animates, everything is drawn at rest", async () => {
  const container = installDom({ reduced: true });
  await render(container, <Pane />);
  expect(animations.length).toBe(0);
  expect(frames.length).toBe(0);
  for (const element of container.querySelectorAll<HTMLElement>(".acpmux-empty *, .acpmux-composer")) {
    expect(element.style.opacity).toBe("");
    expect(element.style.transform).toBe("");
  }
});

test("the app's motion switch off draws at rest too", async () => {
  const container = installDom();
  document.documentElement.dataset.cmuxMotion = "off";
  await render(container, <Pane />);
  expect(animations.length).toBe(0);
});

test("entrance off plays nothing", async () => {
  const container = installDom();
  await render(container, <Pane entrance="off" />);
  expect(animations.length).toBe(0);
});

test("once per chat: re-renders and a remount of the same chat's hero play nothing more", async () => {
  const container = installDom();
  await render(container, <Pane chat="a" />);
  const first = animations.length;
  expect(first).toBeGreaterThan(0);
  // A re-render of the same hero.
  await render(container, <Pane chat="a" />);
  expect(animations.length).toBe(first);
  // The hero unmounts and mounts again for the same chat (the harness picker closing, a reconnect).
  await render(container, <Pane chat="a" hero={false} />);
  await render(container, <Pane chat="a" />);
  expect(animations.length).toBe(first);
  // Another new chat plays its own entrance.
  await render(container, <Pane chat="b" hero={false} />);
  await render(container, <Pane chat="b" />);
  expect(animations.length).toBe(first * 2);
});
