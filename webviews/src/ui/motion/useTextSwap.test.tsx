// l10n-allow-file: test fixture labels, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MOTION_MS } from "../../motion/scale.generated";
import {
  TEXT_SWAP_FADE,
  TEXT_SWAP_GONE_AT,
  TEXT_SWAP_MAX_GHOSTS,
  TEXT_SWAP_RISE_PX,
  TEXT_SWAP_ROOT,
  TEXT_SWAP_SHOW_FROM,
  useTextSwap,
} from "./useTextSwap";
import { settleReact } from "../../../test/support/domTeardown";

// The live line's words change as Claude desktop's do (Leo, 2026-11-05): the new words are in the
// DOM on the commit, the old ones leave as an inert copy, what follows slides by the width change,
// and the motion is paint only, finite, coalesced, and nothing at all with motion off.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

type Played = {
  element: HTMLElement;
  frames: Keyframe[];
  timing: KeyframeAnimationOptions;
  animation: FakeAnimation;
};
type FakeAnimation = {
  cancel(): void;
  finish(): void;
  onfinish: (() => void) | null;
  oncancel: (() => void) | null;
  cancelled: boolean;
};
let played: Played[] = [];
/// Each label's laid-out width (data-width), read by the fake ResizeObserver and getBoundingClientRect.
const widthOf = (element: Element) => Number((element as HTMLElement).dataset.width ?? 0);

function installDom(options: { reduced?: boolean } = {}): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const win = dom.window as unknown as Window & typeof globalThis;
  win.matchMedia = ((query: string) => ({
    matches: Boolean(options.reduced) && query.includes("reduce"),
  })) as never;
  win.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const width = widthOf(this);
    return {
      x: 0,
      y: 0,
      left: 0,
      top: 0,
      width,
      height: 20,
      right: width,
      bottom: 20,
      toJSON() {},
    } as DOMRect;
  };
  // Each label's left edge (data-left): a mark before it moves it.
  Object.defineProperty(win.HTMLElement.prototype, "offsetLeft", {
    configurable: true,
    get(this: HTMLElement) {
      return Number(this.dataset.left ?? 0);
    },
  });
  // A ResizeObserver that reports the laid-out width when it starts observing and on `resized()`.
  const observed = new Set<{ element: Element; callback: ResizeObserverCallback }>();
  (win as unknown as { ResizeObserver: unknown }).ResizeObserver = class {
    entries: { element: Element; callback: ResizeObserverCallback }[] = [];
    constructor(private callback: ResizeObserverCallback) {}
    observe(element: Element) {
      const entry = { element, callback: this.callback };
      observed.add(entry);
      this.entries.push(entry);
      report(entry);
    }
    disconnect() {
      for (const entry of this.entries) observed.delete(entry);
    }
  };
  const report = ({ element, callback }: { element: Element; callback: ResizeObserverCallback }) =>
    callback(
      [
        {
          target: element,
          borderBoxSize: [{ inlineSize: widthOf(element), blockSize: 20 }],
        } as never,
      ],
      {} as ResizeObserver,
    );
  resized = () => observed.forEach(report);
  win.HTMLElement.prototype.animate = function (
    this: HTMLElement,
    frames: Keyframe[],
    timing: KeyframeAnimationOptions,
  ) {
    const animation: FakeAnimation = {
      cancelled: false,
      onfinish: null,
      oncancel: null,
      cancel() {
        this.cancelled = true;
        this.oncancel?.();
      },
      finish() {
        this.onfinish?.();
      },
    };
    played.push({ element: this, frames, timing, animation });
    return animation as unknown as Animation;
  } as never;
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return win.document.getElementById("root")!;
}
let resized = () => {};

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  played = [];
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

let say: (text: string) => void = () => {};
let mark: (on: boolean) => void = () => {};
let tick: () => void = () => {};
/// Each label's width: its length at 7 px a character.
const px = (text: string) => String(text.length * 7);

/// The live line's shape: the words, a lit layer over them, the clock after them, an absolute hint.
function Line() {
  const [text, setText] = useState("Reading daemon log");
  const [seconds, setSeconds] = useState(4);
  const [glyph, setGlyph] = useState(false);
  say = setText;
  mark = setGlyph;
  tick = () => setSeconds((value) => value + 1);
  const words = useTextSwap<HTMLSpanElement>(text);
  return (
    <div className="line" {...{ [TEXT_SWAP_ROOT]: "" }}>
      <span className="row">
        {glyph && <span className="glyph" />}
        <output>
          <span ref={words} className="words" data-width={px(text)} data-left={glyph ? 22 : 0}>
            {text}
          </span>
          <span className="band" style={{ position: "absolute" }} {...{ [TEXT_SWAP_FADE]: "" }} />
        </output>
        <span className="time">7m {seconds}s</span>
      </span>
      <span className="hint" style={{ position: "absolute" }} />
    </div>
  );
}

async function mountLine(options: { reduced?: boolean; motion?: string } = {}) {
  const mount = installDom(options);
  if (options.motion) mount.ownerDocument.documentElement.dataset.cmuxMotion = options.motion;
  await act(async () => {
    root = createRoot(mount);
    root.render(<Line />);
  });
  return mount;
}

const ghosts = (mount: HTMLElement) => [...mount.querySelectorAll<HTMLElement>(".ui-text-swap__ghost")];
const on = (selector: string) => played.filter((entry) => entry.element.matches(selector));

test("the first frame and the clock's ticks move nothing", async () => {
  const mount = await mountLine();
  await act(async () => tick());
  await act(async () => tick());
  expect(played).toEqual([]);
  expect(ghosts(mount)).toEqual([]);
  expect(mount.querySelector(".time")!.textContent).toBe("7m 6s");
});

test("a new call's words are in the DOM on the commit; the old ones leave as an inert copy", async () => {
  const mount = await mountLine();
  await act(async () => say("Running a command"));
  const words = mount.querySelector<HTMLElement>(".words:not(.ui-text-swap__ghost)")!;
  expect(words.textContent).toBe("Running a command");
  const [ghost] = ghosts(mount);
  expect(ghost!.textContent).toBe("Reading daemon log");
  expect(ghost!.getAttribute("aria-hidden")).toBe("true");
  expect(ghost!.hasAttribute("data-find-skip")).toBe(true);
  expect(ghost!.hasAttribute("inert")).toBe(true);
  expect(ghost!.style.position).toBe("absolute");
  // The old words keep their old width, so their ellipsis reads as it did.
  expect(ghost!.style.width).toBe(`${18 * 7}px`);
});

test("the old words rise out, the new rise in, and the clock slides by the width change, on the compositor", async () => {
  await mountLine();
  await act(async () => say("Running a command"));
  const [out] = on(".ui-text-swap__ghost");
  const [incoming] = on(".words:not(.ui-text-swap__ghost)");
  const [time, ...others] = on(".time");
  expect(others).toEqual([]);
  // The absolute layers stay put; the lit layer fades in with the new words.
  expect(on(".hint")).toEqual([]);
  expect(on(".band").map((entry) => entry.frames)).toEqual([[{ opacity: 0 }, { opacity: 1 }]]);
  for (const entry of [out!, incoming!, time!]) {
    for (const frame of entry.frames)
      for (const key of Object.keys(frame)) expect(["opacity", "transform", "offset"]).toContain(key);
    expect(Number(entry.timing.duration)).toBeLessThanOrEqual(MOTION_MS.standard);
  }
  expect(out!.frames.at(-1)).toMatchObject({
    opacity: 0,
    transform: `translateY(${-TEXT_SWAP_RISE_PX}px)`,
  });
  expect(incoming!.frames[0]).toMatchObject({
    opacity: 0,
    transform: `translateY(${TEXT_SWAP_RISE_PX}px)`,
  });
  expect(incoming!.frames.at(-1)).toMatchObject({ opacity: 1, transform: "translateY(0px)" });
  // 18 characters to 17: the clock starts 7 px right of where it lands.
  expect(time!.frames).toEqual([{ transform: "translateX(7px)" }, { transform: "translateX(0px)" }]);
  // No two texts read over each other: the clock slides fast, the old words are gone halfway
  // through their fade, and the new ones stay unseen while the clock is still crossing them.
  expect(Number(time!.timing.duration)).toBe(MOTION_MS.micro);
  expect(out!.frames.find((frame) => frame.offset !== undefined)).toEqual({
    opacity: 0,
    offset: TEXT_SWAP_GONE_AT,
  });
  expect(incoming!.frames.find((frame) => frame.offset !== undefined)).toEqual({
    opacity: 0,
    offset: TEXT_SWAP_SHOW_FROM,
  });
  expect(TEXT_SWAP_SHOW_FROM * Number(incoming!.timing.duration)).toBeGreaterThanOrEqual(MOTION_MS.micro / 2);
});

test("longer words push the clock out of their way as they rise in", async () => {
  const mount = await mountLine();
  await act(async () => say("Checking time and REST quota"));
  resized();
  const [incoming] = on(".words:not(.ui-text-swap__ghost)");
  const [time] = on(".time");
  const grow = (28 - 18) * 7;
  expect(time!.frames[0]).toEqual({ transform: `translateX(${-grow}px)` });
  expect(incoming!.frames[0]).toMatchObject({ opacity: 0 });
  // The clock slides right across where the new words land: they stay unseen until it has landed
  // (router review F1), not from TEXT_SWAP_SHOW_FROM while it still crosses them.
  const reveal = incoming!.frames.find((frame) => frame.offset !== undefined)!;
  expect(reveal.opacity).toBe(0);
  expect(Number(reveal.offset) * Number(incoming!.timing.duration)).toBeGreaterThanOrEqual(
    Number(time!.timing.duration),
  );
  expect(ghosts(mount)).toHaveLength(1);
});

test("a mark that comes with the new call moves the clock by where the words end, not their width alone", async () => {
  const mount = await mountLine();
  // One character longer, and a 22 px command glyph now stands before the words.
  await act(async () => {
    mark(true);
    say("Running bun tests a");
  });
  const [time] = on(".time");
  expect(time!.frames[0]).toEqual({ transform: `translateX(${-22 + -7}px)` });
  // The old words leave from where they stood, left of the glyph's new place.
  expect(ghosts(mount)[0]!.style.left).toBe("0px");
});

test("the old copy goes when its fade ends, and every copy goes on unmount", async () => {
  const mount = await mountLine();
  await act(async () => say("Running a command"));
  on(".ui-text-swap__ghost")[0]!.animation.finish();
  expect(ghosts(mount)).toEqual([]);
  await act(async () => say("Checking time"));
  expect(ghosts(mount)).toHaveLength(1);
  await act(async () => root!.unmount());
  root = undefined;
  expect(ghosts(mount)).toEqual([]);
});

test("calls that change faster than the motion cancel it and keep at most two old copies", async () => {
  const mount = await mountLine();
  for (const text of ["Running a command", "Checking time", "Finding callers", "Reading the daemon log"]) {
    await act(async () => say(text));
    resized();
  }
  expect(ghosts(mount).length).toBeLessThanOrEqual(TEXT_SWAP_MAX_GHOSTS);
  // A copy dropped early stops its fade too: no animation runs on a detached copy.
  for (const entry of on(".ui-text-swap__ghost"))
    if (!entry.element.isConnected) expect(entry.animation.cancelled).toBe(true);
  expect(on(".ui-text-swap__ghost").filter((entry) => entry.animation.cancelled)).toHaveLength(2);
  expect(
    ghosts(mount)
      .map((ghost) => ghost.textContent)
      .sort(),
  ).toEqual(["Checking time", "Finding callers"]);
  // Only the last change's incoming words and clock are still playing.
  const live = played.filter(
    (entry) => !entry.animation.cancelled && !entry.element.classList.contains("ui-text-swap__ghost"),
  );
  expect(live.map((entry) => entry.element.className).sort()).toEqual(["band", "time", "words"]);
  expect(mount.querySelector(".words:not(.ui-text-swap__ghost)")!.textContent).toBe("Reading the daemon log");
});

test("motion off: the new words show in one frame, with no copy and no animation", async () => {
  for (const motion of ["off"]) {
    const mount = await mountLine({ motion });
    await act(async () => say("Running a command"));
    expect(mount.querySelector(".words")!.textContent).toBe("Running a command");
    expect(ghosts(mount)).toEqual([]);
    expect(played).toEqual([]);
  }
});

test("motion turned off mid-change clears the old words still on the line", async () => {
  const mount = await mountLine();
  await act(async () => say("Running a command"));
  expect(ghosts(mount)).toHaveLength(1);
  mount.ownerDocument.documentElement.dataset.cmuxMotion = "off";
  await act(async () => say("Checking time"));
  // Router review F2: the earlier change's copy goes too, not only the animations it tracks.
  expect(ghosts(mount)).toEqual([]);
  expect(mount.querySelector(".words")!.textContent).toBe("Checking time");
});

test("a hidden page changes the words with no motion", async () => {
  const mount = await mountLine();
  Object.defineProperty(mount.ownerDocument, "visibilityState", {
    configurable: true,
    value: "hidden",
  });
  await act(async () => say("Running a command"));
  expect(ghosts(mount)).toEqual([]);
  expect(played).toEqual([]);
});

test("Reduce Motion crossfades: nothing rises, slides or clips", async () => {
  const mount = await mountLine({ reduced: true });
  await act(async () => say("Running a command"));
  expect(ghosts(mount)).toHaveLength(1);
  expect(on(".time")).toEqual([]);
  for (const entry of played) for (const frame of entry.frames) expect(Object.keys(frame)).toEqual(["opacity"]);
});
