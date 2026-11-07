import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SPRING } from "../../motion/scale.generated";
import { DepthLayer } from "./DepthLayer";
import { motionMode } from "./motionMode";
import { SlidingIndicator } from "./SlidingIndicator";
import { swapFrames, ViewSwap } from "./ViewSwap";

// The ui/motion primitives: the selection and the new view are there on the click, and the motion is
// transform (or opacity, clip) only, finite, and off under Reduce Motion or motion off.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

type Played = { element: Element; frames: Keyframe[]; timing: KeyframeAnimationOptions };
let played: Played[] = [];
let animations: Animation[] = [];

function installDom(options: { reduced?: boolean; noLinear?: boolean } = {}): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const win = dom.window as unknown as Window & typeof globalThis;
  win.matchMedia = ((query: string) => ({ matches: Boolean(options.reduced) && query.includes("reduce") })) as never;
  // An engine with `linear()` easing, or (noLinear) one without it, like WebKit on macOS 14.0 and 14.1.
  Object.defineProperty(win, "CSS", {
    configurable: true,
    value: { supports: (_property: string, value: string) => !(options.noLinear && value.startsWith("linear(")) },
  });
  // jsdom lays nothing out: each element's box is its data-box (x,y,w,h), the host's at 0,0.
  win.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const [x = 0, y = 0, w = 0, h = 0] = (this.dataset.box ?? "").split(",").map(Number);
    return { x, y, left: x, top: y, width: w, height: h, right: x + w, bottom: y + h, toJSON() {} } as DOMRect;
  };
  win.HTMLElement.prototype.animate = function (
    this: HTMLElement,
    frames: Keyframe[],
    timing: KeyframeAnimationOptions,
  ) {
    played.push({ element: this, frames, timing });
    const animation = { cancel() {}, playState: "running", onfinish: null } as unknown as Animation;
    animations.push(animation);
    return animation;
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

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  played = [];
  animations = [];
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

let select: (index: number) => void = () => {};

function Tabs() {
  const [value, setValue] = useState(0);
  select = setValue;
  return (
    <div className="ui-slide-host" data-box="0,0,200,32">
      <SlidingIndicator selected={value} look="pill" />
      {["A", "Bbbb"].map((label, index) => (
        <button
          key={label}
          type="button"
          role="tab"
          className="ui-slide-item"
          aria-selected={index === value}
          data-box={index === 0 ? "4,4,40,24" : "48,4,80,24"}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

test("the indicator sits on the selected tab in its first frame, with no motion", async () => {
  const mount = installDom();
  await act(async () => {
    root = createRoot(mount);
    root.render(<Tabs />);
  });
  const mark = mount.querySelector<HTMLElement>(".ui-slide-indicator")!;
  expect(mark.style.transform).toBe("translate(4px, 4px)");
  expect(mark.style.width).toBe("40px");
  expect(played).toEqual([]);
});

test("a selection change places it on the new tab at once and slides on transform only, on the spring", async () => {
  const mount = installDom();
  await act(async () => {
    root = createRoot(mount);
    root.render(<Tabs />);
  });
  await act(async () => select(1));
  const mark = mount.querySelector<HTMLElement>(".ui-slide-indicator")!;
  // Its resting place is the new tab's in the same commit; the animation plays over it.
  expect(mark.style.transform).toBe("translate(48px, 4px)");
  expect(mark.style.width).toBe("80px");
  expect(mount.querySelectorAll('[aria-selected="true"]')[0]!.textContent).toBe("Bbbb");
  expect(played).toHaveLength(1);
  const [{ frames, timing }] = played as [Played];
  for (const frame of frames) expect(Object.keys(frame)).toEqual(["transform"]);
  expect(frames[0]!.transform).toBe("translate(4px, 4px) scale(0.5, 1)");
  expect(timing).toEqual({ duration: MOTION_MS.large, easing: MOTION_SPRING });
});

test("a size change during a slide re-places the highlight when the slide finishes", async () => {
  const mount = installDom();
  const observed: (() => void)[] = [];
  const before = scope.ResizeObserver;
  scope.ResizeObserver = class {
    constructor(callback: () => void) {
      observed.push(callback);
    }
    observe() {}
    disconnect() {}
  };
  try {
    await act(async () => {
      root = createRoot(mount);
      root.render(<Tabs />);
    });
    await act(async () => select(1));
    const mark = mount.querySelector<HTMLElement>(".ui-slide-indicator")!;
    // A font load widens the new tab mid-slide; the slide keeps its course.
    mount.querySelectorAll<HTMLElement>(".ui-slide-item")[1]!.dataset.box = "48,4,96,24";
    for (const callback of observed) callback();
    expect(mark.style.width).toBe("80px");
    // It lands on the tab's new box, with no second slide.
    const [slide] = animations as [Animation];
    await act(async () => void slide.onfinish?.call(slide, new dom!.window.Event("finish") as AnimationPlaybackEvent));
    expect(mark.style.width).toBe("96px");
    expect(mark.style.transform).toBe("translate(48px, 4px)");
    expect(played).toHaveLength(1);
  } finally {
    if (before === undefined) delete scope.ResizeObserver;
    else scope.ResizeObserver = before;
  }
});

test("an engine without linear() easing slides on the ease-out instead of throwing", async () => {
  const mount = installDom({ noLinear: true });
  await act(async () => {
    root = createRoot(mount);
    root.render(<Tabs />);
  });
  await act(async () => select(1));
  expect(played).toHaveLength(1);
  expect(played[0]!.timing).toEqual({ duration: MOTION_MS.large, easing: MOTION_EASE_OUT });
});

test("Reduce Motion and motion off place it with no slide", async () => {
  for (const setup of [
    () => installDom({ reduced: true }),
    () => {
      const mount = installDom();
      mount.ownerDocument.documentElement.dataset.agentMotion = "off";
      return mount;
    },
  ]) {
    const mount = setup();
    await act(async () => {
      root = createRoot(mount);
      root.render(<Tabs />);
    });
    await act(async () => select(1));
    expect(mount.querySelector<HTMLElement>(".ui-slide-indicator")!.style.transform).toBe("translate(48px, 4px)");
    expect(played).toEqual([]);
    await act(async () => root!.unmount());
    root = undefined;
    dom?.window.close();
  }
});

test("motionMode reads the host's switches", () => {
  const mount = installDom();
  const doc = mount.ownerDocument;
  expect(motionMode(doc)).toBe("full");
  doc.documentElement.dataset.cmuxMotion = "reduced";
  expect(motionMode(doc)).toBe("reduced");
  doc.documentElement.dataset.cmuxMotion = "off";
  expect(motionMode(doc)).toBe("none");
});

test("a view swap shows the new content in the same commit and animates only paint", async () => {
  const mount = installDom();
  let show: (key: string) => void = () => {};
  function Swap() {
    const [key, setKey] = useState("one");
    show = setKey;
    return (
      <ViewSwap swapKey={key} order={key === "one" ? 0 : 1} look="slide">
        <button type="button">{key}</button>
      </ViewSwap>
    );
  }
  await act(async () => {
    root = createRoot(mount);
    root.render(<Swap />);
  });
  expect(played).toEqual([]);
  await act(async () => show("two"));
  expect(mount.querySelector("button")!.textContent).toBe("two");
  expect(played).toHaveLength(1);
  for (const frame of played[0]!.frames) expect(Object.keys(frame).sort()).toEqual(["opacity", "transform"]);
  expect(played[0]!.timing.duration).toBeLessThanOrEqual(MOTION_MS.large);
});

test("every swap look moves paint only and comes from the side it is told", () => {
  for (const look of ["fade", "slide", "wipe", "sweep"] as const) {
    const frames = swapFrames(look, "forward");
    const keys = new Set([...(frames.content ?? []), ...(frames.band ?? [])].flatMap((frame) => Object.keys(frame)));
    for (const key of keys) expect(["opacity", "transform", "clipPath"]).toContain(key);
  }
  const first = (direction: "forward" | "back") => (swapFrames("slide", direction).content![0] as Keyframe).transform;
  expect(first("forward")).toBe("translateX(8px)");
  expect(first("back")).toBe("translateX(-8px)");
});

test("the depth layer's drift takes the shared motion reading, at mount and when the page shows", async () => {
  const mount = installDom();
  const doc = mount.ownerDocument;
  await act(async () => {
    root = createRoot(mount);
    root.render(<DepthLayer look="drift" />);
  });
  const layer = mount.querySelector<HTMLElement>(".ui-depth")!;
  expect(layer.dataset.motion).toBe("full");
  await act(async () => root!.unmount());
  root = undefined;

  // A zero motion token stills it, though no root attribute says so.
  doc.documentElement.style.setProperty("--agent-motion-in", "0ms");
  await act(async () => {
    root = createRoot(mount);
    root.render(<DepthLayer look="drift-parallax" />);
  });
  expect(mount.querySelector<HTMLElement>(".ui-depth")!.dataset.motion).toBe("none");
  await act(async () => root!.unmount());
  root = undefined;
  doc.documentElement.style.removeProperty("--agent-motion-in");

  // Mounted while hidden: paused with no reading; the reading arrives when the page shows.
  let state: DocumentVisibilityState = "hidden";
  Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => state });
  await act(async () => {
    root = createRoot(mount);
    root.render(<DepthLayer look="drift" />);
  });
  const hidden = mount.querySelector<HTMLElement>(".ui-depth")!;
  expect(hidden.dataset.motion).toBeUndefined();
  expect(hidden.dataset.paused).toBe("");
  state = "visible";
  await act(async () => void doc.dispatchEvent(new dom!.window.Event("visibilitychange")));
  expect(hidden.dataset.motion).toBe("full");
  expect(hidden.dataset.paused).toBeUndefined();
});

/** Specificity (ids, classes, types) of one complex selector: :where() weighs nothing, :is() and :not()
 *  weigh their heaviest argument. Enough for motion.css's selectors. */
function specificity(selector: string): [number, number, number] {
  const total: [number, number, number] = [0, 0, 0];
  let rest = selector;
  for (;;) {
    const open = /:(where|is|not)\(/.exec(rest);
    if (!open) break;
    let depth = 1;
    let end = open.index + open[0].length;
    while (depth > 0) {
      if (rest[end] === "(") depth++;
      else if (rest[end] === ")") depth--;
      end++;
    }
    const inner = rest.slice(open.index + open[0].length, end - 1);
    if (open[1] !== "where") {
      const heaviest = splitTop(inner)
        .map(specificity)
        .sort((a, b) => b[0] - a[0] || b[1] - a[1] || b[2] - a[2])[0]!;
      for (const i of [0, 1, 2] as const) total[i] += heaviest[i];
    }
    rest = rest.slice(0, open.index) + " " + rest.slice(end);
  }
  total[0] += (rest.match(/#[\w-]+/g) ?? []).length;
  total[1] += (rest.match(/\.[\w-]+|\[[^\]]*\]|:(?!:)[\w-]+/g) ?? []).length;
  total[2] += (rest.replace(/\[[^\]]*\]/g, "").match(/(^|[\s>+~])[a-z][\w-]*/gi) ?? []).length;
  return total;
}

/** Splits a selector list on its top-level commas. */
function splitTop(list: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < list.length; i++) {
    if (list[i] === "(") depth++;
    else if (list[i] === ")") depth--;
    else if (list[i] === "," && depth === 0) {
      parts.push(list.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(list.slice(start));
  return parts.map((part) => part.trim());
}

test("every motion-off and Reduce Motion rule outranks the depth layer's drift and lean", () => {
  const sheet = readFileSync(new URL("./motion.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [...sheet.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((match) => ({
    selectors: splitTop(match[1]!.replace(/\s+/g, " ").trim()),
    body: match[2]!,
  }));
  const weight = (s: [number, number, number]) => s[0] * 10000 + s[1] * 100 + s[2];
  const moving = rules
    .filter((rule) => /\b(animation|translate):/.test(rule.body) && !/:\s*none/.test(rule.body))
    .flatMap((rule) => rule.selectors)
    .filter((selector) => selector.includes(".ui-depth__wash"));
  const stills = rules.filter((rule) => /animation: none/.test(rule.body)).flatMap((rule) => rule.selectors);
  expect(moving.length).toBeGreaterThanOrEqual(4);
  // Off, Reduce Motion by attribute (both hosts' spellings), and the media query.
  expect(stills.length).toBe(2);
  for (const flag of [
    'data-agent-motion="off"',
    'data-agent-motion="reduced"',
    'data-cmux-motion="off"',
    'data-cmux-motion="reduced"',
  ])
    expect(stills[0]).toContain(flag);
  for (const still of stills)
    for (const move of moving) expect(weight(specificity(still))).toBeGreaterThan(weight(specificity(move)));
  // The drift itself waits for a full motion reading.
  for (const move of moving.filter((selector) => selector.includes("drift")))
    expect(move).toContain('[data-motion="full"]');
});

test("a control that is both revealed and hover-filled keeps both fades", () => {
  const sheet = readFileSync(new URL("./motion.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const body = (selector: string) => {
    const at = sheet.search(new RegExp(`(^|\\})\\s*${selector.replace(/[.[\]]/g, "\\$&")}\\s*\\{`));
    expect(at).toBeGreaterThanOrEqual(0);
    return sheet.slice(sheet.indexOf("{", at + 1) + 1, sheet.indexOf("}", sheet.indexOf("{", at + 1)));
  };
  // The fill names its fade; the reveal's in and out durations ride one property the shown state sets.
  expect(body(".ui-hover-fill")).toContain("--ui-fill-transition:");
  expect(body(".ui-reveal")).toMatch(/transition: opacity var\(--ui-reveal-ms\)/);
  const both = body(".ui-reveal.ui-hover-fill");
  expect(both).toMatch(/opacity var\(--ui-reveal-ms\)/);
  expect(both).toContain("var(--ui-fill-transition)");
  // No shown-state rule resets the whole transition list (which would drop the fill's fade).
  const shown = sheet.slice(sheet.indexOf(".ui-reveal-host:hover .ui-reveal"));
  const shownBody = shown.slice(shown.indexOf("{") + 1, shown.indexOf("}"));
  expect(shownBody).not.toMatch(/transition(-duration)?:/);
  expect(shownBody).toContain("--ui-reveal-ms:");
});

test("a parallax layer mounted while the page is hidden starts leaning when the page shows", async () => {
  const mount = installDom();
  const doc = mount.ownerDocument;
  let state: DocumentVisibilityState = "hidden";
  Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => state });
  mount.dataset.box = "0,0,200,100";
  await act(async () => {
    root = createRoot(mount);
    root.render(<DepthLayer look="parallax" />);
  });
  const layer = mount.querySelector<HTMLElement>(".ui-depth")!;
  const move = () =>
    mount.dispatchEvent(new dom!.window.MouseEvent("pointermove", { clientX: 200, clientY: 100, bubbles: true }));
  move();
  expect(layer.style.getPropertyValue("--ui-depth-x")).toBe("");
  state = "visible";
  await act(async () => void doc.dispatchEvent(new dom!.window.Event("visibilitychange")));
  expect(layer.dataset.motion).toBe("full");
  move();
  expect(layer.style.getPropertyValue("--ui-depth-x")).toBe("1.000");
  expect(layer.style.getPropertyValue("--ui-depth-y")).toBe("1.000");
});
