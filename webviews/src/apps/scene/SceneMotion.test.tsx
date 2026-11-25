// The motion contract on the web renderer (cmux-app-host js/ABI.md "Motion"): timings, CSS values,
// the renderer's Web Animations, `pop` and loops, and the particle field. Entering and leaving are
// sceneMotion.tsx's (SceneRenderer.test.tsx).
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { fileURLToPath } from "node:url";
import { settleReact } from "../../../test/support/domTeardown";
import { SceneRenderer } from "./SceneRenderer";
import { loopStyle, parseMotion, sceneTiming, springLinear, trimRange } from "./motionProps";
import { MAX_PARTICLES, ParticleField } from "./particleField";
import { glowFilter, gradientImage, offsetTranslate } from "./sceneStyle";
import { SceneStore, type SceneOp } from "./store";
import { MotionTrack, resetMotionEnvCache } from "./useSceneMotion";

const FULL = { mode: "full", speed: 1 } as const;
const QUICK = { spring: { response: 0.3, dampingFraction: 0.8 } };

describe("timings", () => {
  test("tokens resolve to the contract's springs, fade and clamps", () => {
    // The motion scale's steps are scene.css transitions, not springs.
    for (const step of ["smooth", "snappy", "none"]) expect(parseMotion(step)).toBeNull();
    expect(parseMotion("bouncy")).toEqual({ spring: { response: 0.45, dampingFraction: 0.6 } });
    expect(parseMotion("move")).toEqual({ spring: { response: 0.15, dampingFraction: 1 } });
    expect(parseMotion("fade")).toEqual({ duration: 0.12, curve: "easeOut" });
    expect(parseMotion({ spring: { response: 40, dampingFraction: 0.01 } })).toEqual({
      spring: { response: 10, dampingFraction: 0.3 },
    });
    expect(parseMotion({ duration: 0, curve: "wobble" })).toEqual({ duration: 0.05, curve: "easeOut" });
    expect(parseMotion("nope")).toBeNull();
    expect(parseMotion(null)).toBeNull();
  });

  test("a bouncy spring overshoots its target and a critically damped one never does", () => {
    const points = (easing: string) =>
      easing
        .slice("linear(".length, -1)
        .split(",")
        .map((p) => Number.parseFloat(p));
    const bouncy = points(springLinear({ response: 0.45, dampingFraction: 0.6 }).easing);
    expect(Math.max(...bouncy)).toBeGreaterThan(1.05);
    expect(bouncy.at(0)).toBe(0);
    expect(bouncy.at(-1)).toBe(1);
    const move = points(springLinear({ response: 0.15, dampingFraction: 1 }).easing);
    expect(Math.max(...move)).toBeLessThanOrEqual(1);
  });

  test("Reduce Motion and motion off make every change instant; the speed scales durations", () => {
    expect(sceneTiming("bouncy", { mode: "reduced", speed: 1 })).toBeNull();
    expect(sceneTiming("bouncy", { mode: "none", speed: 1 })).toBeNull();
    const fast = sceneTiming({ duration: 0.2, curve: "linear" }, FULL)!;
    const normal = sceneTiming({ duration: 0.2, curve: "linear" }, { mode: "full", speed: 1.5 })!;
    expect(fast).toEqual({ duration: 200, easing: "linear" });
    expect(normal.duration).toBeCloseTo(300);
  });
});

describe("props as CSS", () => {
  test("gradient angles: 0 runs left to right, 90 (default) top to bottom", () => {
    expect(gradientImage({ colors: ["#FF0000", "#0000FF"], angle: 0 })).toBe(
      "linear-gradient(90deg, #FF0000, #0000FF)",
    );
    expect(gradientImage({ colors: ["#FF0000", "#0000FF"] })).toBe("linear-gradient(180deg, #FF0000, #0000FF)");
    expect(gradientImage({ colors: ["accent"] })).toBe(
      "linear-gradient(180deg, var(--cmux-accent, var(--agent-text)), var(--cmux-accent, var(--agent-text)))",
    );
    expect(gradientImage({ colors: ["url(x)"] })).toBeUndefined();
  });

  test("glow is a zero-offset drop shadow in the tone, at its opacity", () => {
    expect(glowFilter({ color: "#FFD700", radius: 8 })).toBe("drop-shadow(0 0 8px #FFD700)");
    expect(glowFilter({ color: "warning", radius: 6, opacity: 0.5 })).toBe(
      "drop-shadow(0 0 6px color-mix(in srgb, var(--agent-status-warning) 50%, transparent))",
    );
    expect(glowFilter({ color: "javascript:", radius: 6 })).toBeUndefined();
  });

  test("offset, trim and loops", () => {
    expect(offsetTranslate({ y: -4 })).toBe("0px -4px");
    expect(offsetTranslate(null)).toBeUndefined();
    expect(trimRange({ to: 0.75 })).toEqual([0, 0.75]);
    expect(trimRange({ from: 0.5, to: 0.2 })).toEqual([0.5, 0.5]);
    expect(trimRange({})).toBeUndefined();
    expect(loopStyle({ effect: "pulse" })).toEqual({
      effect: "pulse",
      vars: { "--scene-loop-period": "1200ms", "--scene-loop-amount": "1", "--scene-loop-turn": "360deg" },
    });
    expect(loopStyle({ effect: "spin", period: 4, amount: -1 }, 1.5)!.vars).toEqual({
      "--scene-loop-period": "6000ms",
      "--scene-loop-amount": "-1",
      "--scene-loop-turn": "-360deg",
    });
    expect(loopStyle({ effect: "teleport" })).toBeUndefined();
  });
});

describe("particles", () => {
  const seeded = () => {
    let seed = 7;
    return () => {
      seed = (seed * 16807) % 2147483647;
      return seed / 2147483647;
    };
  };

  test("confetti emits only on a burst, falls, and clears", () => {
    const field = new ParticleField("confetti", null, seeded());
    field.resize(320, 200);
    expect(field.continuous).toBe(false);
    field.step(1);
    expect(field.particles.length).toBe(0);
    field.burst();
    expect(field.particles.length).toBe(110);
    expect(field.shapes().every((s) => s.kind === "rect")).toBe(true);
    for (let i = 0; i < 100; i += 1) field.step(0.05);
    expect(field.particles.length).toBe(0);
    expect(field.active).toBe(false);
  });

  test("continuous presets emit at their rate and never pass the cap", () => {
    const snow = new ParticleField("snow", ["#FFFFFF"], seeded());
    snow.resize(320, 200);
    snow.prewarm(3);
    const steady = snow.particles.length;
    expect(steady).toBeGreaterThan(20);
    snow.setRate(0);
    expect(snow.continuous).toBe(false);
    const rain = new ParticleField("rain", null, seeded());
    rain.resize(2000, 2000);
    rain.setRate(40);
    expect(rain.rate).toBe(4);
    for (let i = 0; i < 40; i += 1) rain.step(0.05);
    expect(rain.particles.length).toBeLessThanOrEqual(MAX_PARTICLES);
  });

  test("sparkles burst from the center", () => {
    const field = new ParticleField("sparkles", null, seeded());
    field.resize(100, 100);
    field.burst();
    expect(field.particles.every((p) => p.x === 50 && p.y === 50)).toBe(true);
  });
});

// ---------------------------------------------------------------------------------------------
// The renderer, in a DOM whose Element.animate records each animation.

type Recorded = {
  element: Element;
  keyframes: Keyframe[];
  options: KeyframeAnimationOptions;
  animation: { playState: string; onfinish: (() => void) | null; oncancel: (() => void) | null; cancel(): void };
};

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
  resetMotionEnvCache();
});

function render(ops: SceneOp[]) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const values: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    ShadowRoot: dom.window.ShadowRoot,
    DocumentFragment: dom.window.DocumentFragment,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    Event: dom.window.Event,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(values)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const animations: Recorded[] = [];
  (dom.window.Element.prototype as unknown as { animate: unknown }).animate = function (
    this: Element,
    keyframes: Keyframe[],
    options: KeyframeAnimationOptions,
  ) {
    const animation: Recorded["animation"] = {
      playState: "running",
      onfinish: null,
      oncancel: null,
      cancel() {
        this.playState = "idle";
        this.oncancel?.();
      },
    };
    animations.push({ element: this, keyframes, options, animation });
    return animation;
  };
  resetMotionEnvCache();
  const container = document.getElementById("root")!;
  const clientPath = fileURLToPath(
    new URL("./cjs/react-dom-client.development.js", import.meta.resolve("react-dom/client")),
  );
  delete require.cache[clientPath];
  const { createRoot } = require(clientPath) as typeof import("react-dom/client");
  const store = new SceneStore();
  store.apply(ops);
  root = createRoot(container);
  act(() => root!.render(<SceneRenderer store={store} dispatch={() => {}} />));
  const apply = (next: SceneOp[]) => act(() => store.apply(next));
  const node = (id: string) => container.querySelector(`[data-app-node="${id}"]`) as HTMLElement | null;
  return { container, store, animations, apply, node };
}

const stack = (child: SceneOp & { op: "create" }): SceneOp[] => [
  { op: "create", id: "root", type: "VStack" },
  child,
  { op: "children", id: "root", children: [child.id] },
  { op: "root", id: "root" },
];

describe("renderer", () => {
  test("a changed prop animates from the value on screen on the node's motion", () => {
    const view = render(
      stack({ op: "create", id: "t", type: "Text", props: { text: "x", opacity: 0.2, animation: QUICK } }),
    );
    expect(view.animations).toHaveLength(0);
    view.apply([{ op: "update", id: "t", props: { opacity: 1 } }]);
    expect(view.animations).toHaveLength(1);
    const [first] = view.animations;
    expect(first!.element).toBe(view.node("t")!);
    expect(first!.keyframes).toEqual([{ opacity: "0.2" }, { opacity: "1" }]);
    expect(first!.options.duration).toBeCloseTo(springLinear({ response: 0.3, dampingFraction: 0.8 }).end * 1000);
  });

  test("without an animation prop, or with motion off, a change is instant", () => {
    const view = render(stack({ op: "create", id: "t", type: "Text", props: { text: "x", opacity: 0.2 } }));
    view.apply([{ op: "update", id: "t", props: { opacity: 1 } }]);
    expect(view.animations).toHaveLength(0);
    view.apply([{ op: "update", id: "t", props: { animation: QUICK } }]);
    document.documentElement.dataset.cmuxMotion = "off";
    resetMotionEnvCache();
    view.apply([{ op: "update", id: "t", props: { opacity: 0.5 } }]);
    expect(view.animations).toHaveLength(0);
  });

  test("loops mark the node for scene.css with the period and amount", () => {
    const view = render(
      stack({ op: "create", id: "t", type: "Text", props: { text: "x", loop: { effect: "wiggle", amount: 2 } } }),
    );
    const element = view.node("t")!;
    expect(element.dataset.loop).toBe("wiggle");
    expect(element.style.getPropertyValue("--scene-loop-period")).toBe("600ms");
    expect(element.style.getPropertyValue("--scene-loop-amount")).toBe("2");
    view.apply([{ op: "update", id: "t", props: { loop: null } }]);
    expect(element.dataset.loop).toBeUndefined();
  });

  test("a trimmed stroked circle draws its outline as SVG from 12 o'clock", () => {
    const view = render(
      stack({
        op: "create",
        id: "ring",
        type: "Circle",
        props: { stroke: "accent", strokeWidth: 4, size: 40, trim: { to: 0.75 } },
      }),
    );
    const circle = view.node("ring")!.querySelector("circle")!;
    expect(circle.getAttribute("pathLength")).toBe("1");
    expect(circle.getAttribute("transform")).toBe("rotate(-90 20 20)");
    expect(circle.getAttribute("r")).toBe("18");
    expect(circle.getAttribute("stroke-dasharray")).toBe("0.75 1");
    expect(view.node("ring")!.style.borderStyle).toBe("");
  });

  test("smooth and snappy are scene.css transitions: no Web Animation; a spring is one", () => {
    const view = render(
      stack({ op: "create", id: "t", type: "Text", props: { text: "x", opacity: 0.2, animation: "smooth" } }),
    );
    expect(view.node("t")!.dataset.animation).toBe("smooth");
    view.apply([{ op: "update", id: "t", props: { opacity: 1 } }]);
    expect(view.animations).toHaveLength(0);
    view.apply([{ op: "update", id: "t", props: { animation: QUICK } }]);
    view.apply([{ op: "update", id: "t", props: { opacity: 0.4 } }]);
    expect(view.node("t")!.dataset.animation).toBeUndefined();
    expect(view.animations).toHaveLength(1);
  });

  test("pop enters after the first frame and leaves, kept by its parent, as scene.css's other transitions", () => {
    const view = render(stack({ op: "create", id: "t", type: "Text", props: { text: "x", transition: "pop" } }));
    // The first scene draws without entering.
    expect(view.node("t")!.dataset.entering).toBeUndefined();
    view.apply([
      { op: "create", id: "u", type: "Text", props: { text: "y", transition: "pop" } },
      { op: "children", id: "root", children: ["t", "u"] },
    ]);
    expect(view.node("u")!.dataset.transition).toBe("pop");
    expect(view.node("u")!.dataset.entering).toBe("");
    view.apply([
      { op: "remove", id: "u" },
      { op: "children", id: "root", children: ["t"] },
    ]);
    expect(view.node("u")!.dataset.leaving).toBe("");
    expect(view.node("u")!.getAttribute("aria-hidden")).toBe("true");
    // No Web Animation: the enter and leave are CSS.
    expect(view.animations).toHaveLength(0);
  });

  test("Particles draws one canvas that takes no input", () => {
    const view = render(
      stack({
        op: "create",
        id: "p",
        type: "Particles",
        props: { preset: "snow", frame: { width: 200, height: 100 } },
      }),
    );
    const element = view.node("p")!;
    expect(element.getAttribute("aria-hidden")).toBe("true");
    expect(element.querySelectorAll("canvas")).toHaveLength(1);
  });

  test("a track animates from the value of the last commit", () => {
    const view = render(stack({ op: "create", id: "t", type: "Text", props: { text: "x" } }));
    const element = view.node("t")!;
    const track = new MotionTrack();
    element.style.opacity = "0";
    track.update(element, ["opacity"], { duration: 100, easing: "linear" });
    element.style.opacity = "1";
    track.update(element, ["opacity"], { duration: 100, easing: "linear" });
    expect(view.animations.at(-1)!.keyframes).toEqual([{ opacity: "0" }, { opacity: "1" }]);
  });
});
