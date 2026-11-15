// The New Tab style dots' accent mark is the shared sliding indicator (ui/motion useSlidingIndicator,
// design/new-tab.md): in its first frame it sits on the current dot with no motion; a pick places it on
// the new dot at once and slides it there on transform only, over the scale's standard step (180 ms)
// on the ease-out; with Reduce Motion or motion off it is placed with no slide.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { MOTION_EASE_OUT, MOTION_MS } from "../src/motion/scale.generated";
import { DotSwitch } from "../src/agent-session/acpmux/newtab/StyleSwitch";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const saved = new Map(keys.map((key) => [key, scope[key]] as const));
type Played = { frames: Keyframe[]; timing: KeyframeAnimationOptions };
let played: Played[] = [];
let dom: JSDOM | undefined;
let root: Root | undefined;
const options = ["minimal", "cards", "threads"] as const;
type Option = (typeof options)[number];
let pick: (option: Option) => void = () => {};

function install(setup: { reduced?: boolean; off?: boolean } = {}): HTMLElement {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/", pretendToBeVisual: true });
  const win = dom.window as unknown as Window & typeof globalThis;
  win.matchMedia = ((query: string) => ({ matches: Boolean(setup.reduced) && query.includes("reduce") })) as never;
  if (setup.off) win.document.documentElement.dataset.agentMotion = "off";
  // jsdom lays nothing out: a dot's box is its place in the row (24 px each), the row's at 0,0.
  win.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const index = this.dataset.style ? options.indexOf(this.dataset.style as Option) : -1;
    const [x, w, h] = index >= 0 ? [index * 24, 24, 24] : [0, 72, 24];
    return { x, y: 0, left: x, top: 0, width: w, height: h, right: x + w, bottom: h, toJSON() {} } as DOMRect;
  };
  win.HTMLElement.prototype.animate = function (frames: Keyframe[], timing: KeyframeAnimationOptions) {
    played.push({ frames, timing });
    return { cancel() {}, playState: "running", onfinish: null } as unknown as Animation;
  } as never;
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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

function Dots() {
  const [current, setCurrent] = useState<Option>("cards");
  pick = setCurrent;
  return (
    <DotSwitch<Option>
      options={options}
      current={current}
      label="Page look"
      name={(option) => option}
      onPick={setCurrent}
      onCancel={() => {}}
    />
  );
}

async function mount(setup?: { reduced?: boolean; off?: boolean }) {
  const host = install(setup);
  await act(async () => {
    root = createRoot(host);
    root.render(<Dots />);
  });
  return host.querySelector<HTMLElement>(".nt-style-mark")!;
}

test("the accent mark sits on the current dot in its first frame, with no motion", async () => {
  const mark = await mount();
  expect(mark.style.transform).toBe("translate(24px, 0px)");
  expect(mark.style.width).toBe("24px");
  expect(played).toEqual([]);
  // No settle state: the row draws its final state in the first commit.
  expect(mark.parentElement!.hasAttribute("data-settled")).toBe(false);
});

test("a pick places the mark on the new dot at once and slides it on transform over 180 ms", async () => {
  const mark = await mount();
  await act(async () => pick("threads"));
  expect(mark.style.transform).toBe("translate(48px, 0px)");
  expect(played).toHaveLength(1);
  const [{ frames, timing }] = played as [Played];
  for (const frame of frames) expect(Object.keys(frame)).toEqual(["transform"]);
  expect(frames[0]!.transform).toBe("translate(24px, 0px) scale(1, 1)");
  expect(timing).toEqual({ duration: MOTION_MS.standard, easing: MOTION_EASE_OUT });
});

test("Reduce Motion and motion off place the mark on a pick with no slide", async () => {
  for (const setup of [{ reduced: true }, { off: true }]) {
    const mark = await mount(setup);
    await act(async () => pick("minimal"));
    expect(mark.style.transform).toBe("translate(0px, 0px)");
    expect(played).toEqual([]);
    await act(async () => root!.unmount());
    root = undefined;
    dom?.window.close();
  }
});
