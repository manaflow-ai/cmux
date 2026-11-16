// The app scene motion contract (cmux-app-host js/ABI.md "Motion") on the web: the motion an app
// declares as props, resolved to Web Animations timings and CSS values. Everything here is pure or
// reads the document once per call; nothing runs per frame. The renderer (SceneRenderer.tsx) starts
// the animations, CSS (scene.css) runs the loops, and SceneParticles.tsx draws particles.
import {
  MOTION_FADES,
  MOTION_SPRINGS,
  springStepResponse,
  springVisibleEnd,
  type SpringParameters,
} from "../../files-panel-motion";
import { MOTION_EASE_OUT } from "../../motion/scale.generated";
import { motionMode, springEasing, type MotionMode } from "../../ui/motion/motionMode";
import { sceneNumber, sceneRecord } from "./sceneStyle";

/** A resolved motion: a spring sampled into a `linear()` easing, or a timed curve. Milliseconds. */
export type SceneTiming = { duration: number; easing: string };

/** `snappy` and `bouncy` (the one token that overshoots, for playful reveals): the contract's own springs. */
export const SCENE_SPRINGS = {
  ...MOTION_SPRINGS,
  snappy: { response: 0.3, dampingFraction: 0.8 },
  bouncy: { response: 0.45, dampingFraction: 0.6 },
} as const satisfies Record<string, SpringParameters>;

const CURVES: Record<string, string> = {
  easeOut: MOTION_EASE_OUT,
  // The standard ease-in-out (CAMediaTimingFunction .easeInEaseOut), the timed curve's other choice.
  easeInOut: "cubic-bezier(0.42, 0, 0.58, 1)",
  linear: "linear",
};

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);

/** The contract's clamps: damping to [0.3, 1], response and duration to [0.05, 10] s. */
export function parseMotion(value: unknown): { spring: SpringParameters } | { duration: number; curve: string } | null {
  if (typeof value === "string") {
    if (value === "fade") return { duration: MOTION_FADES.fadeIn / 1000, curve: "easeOut" };
    const spring = (SCENE_SPRINGS as Record<string, SpringParameters>)[value];
    return spring ? { spring } : null;
  }
  const record = sceneRecord(value);
  const spring = sceneRecord(record.spring);
  const response = sceneNumber(spring.response);
  if (response !== undefined) {
    return {
      spring: {
        response: clamp(response, 0.05, 10),
        dampingFraction: clamp(sceneNumber(spring.dampingFraction) ?? 1, 0.3, 1),
      },
    };
  }
  const duration = sceneNumber(record.duration);
  if (duration === undefined) return null;
  const curve = typeof record.curve === "string" && CURVES[record.curve] ? record.curve : "easeOut";
  return { duration: clamp(duration, 0.05, 10), curve };
}

const springCache = new Map<string, { end: number; easing: string }>();

/** A spring's visible length (s) and its step response as a CSS `linear()` easing (overshoot kept). */
export function springLinear(spring: SpringParameters): { end: number; easing: string } {
  const key = `${spring.response}/${spring.dampingFraction}`;
  const cached = springCache.get(key);
  if (cached) return cached;
  const end = springVisibleEnd(spring);
  // About one point per 60 Hz frame, so an overshoot keeps its peak; at least 12, at most 120.
  const samples = clamp(Math.ceil(end * 60), 12, 120);
  const points: string[] = [];
  for (let index = 0; index <= samples; index += 1) {
    const value = index === samples ? 1 : springStepResponse(spring, (end * index) / samples);
    points.push(String(Math.round(value * 10_000) / 10_000));
  }
  const result = { end, easing: `linear(${points.join(", ")})` };
  if (springCache.size > 64) springCache.clear();
  springCache.set(key, result);
  return result;
}

/** How the scene may move now: the app's motion switch, Reduce Motion and the page's visibility
 * (ui/motion/motionMode.ts), and `ui.animationSpeed` as a time scale (1 fast, 1.5 normal). */
export type SceneMotionEnv = { mode: MotionMode; speed: number };

export function sceneMotionEnv(
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
  node?: Element | null,
): SceneMotionEnv {
  const mode = motionMode(doc, node);
  // The host scales its fade-in token by ui.animationSpeed (120 ms at fast), so the ratio is the speed.
  let speed = 1;
  const root = doc?.documentElement;
  const view = doc?.defaultView;
  if (root && view) {
    const token = view.getComputedStyle(root).getPropertyValue("--agent-motion-in").trim();
    const value = Number.parseFloat(token);
    if (token && Number.isFinite(value) && value > 0) {
      const ms = token.endsWith("ms") ? value : value * 1000;
      speed = clamp(ms / MOTION_FADES.fadeIn, 0.25, 4);
    }
  }
  return { mode, speed };
}

/** The Web Animations timing of `motion`, or null when the scene must not move (an instant change). */
export function sceneTiming(motion: unknown, env: SceneMotionEnv, doc?: Document): SceneTiming | null {
  if (env.mode !== "full") return null;
  const parsed = parseMotion(motion);
  if (!parsed) return null;
  if ("spring" in parsed) {
    const { end, easing } = springLinear(parsed.spring);
    return { duration: end * 1000 * env.speed, easing: springEasing(easing, MOTION_EASE_OUT, doc) };
  }
  return { duration: parsed.duration * 1000 * env.speed, easing: CURVES[parsed.curve] ?? MOTION_EASE_OUT };
}

// ---------------------------------------------------------------------------------------------
// Props as CSS values.

/** `trim` as `[from, to]` fractions of the outline, or undefined when there is none. */
export function trimRange(value: unknown): [number, number] | undefined {
  const trim = sceneRecord(value);
  const to = sceneNumber(trim.to);
  if (to === undefined) return undefined;
  const from = clamp(sceneNumber(trim.from) ?? 0, 0, 1);
  return [from, Math.max(from, clamp(to, 0, 1))];
}

export const LOOP_EFFECTS = ["pulse", "breathe", "spin", "float", "wiggle", "bounce", "shimmer"] as const;
export type SceneLoopEffect = (typeof LOOP_EFFECTS)[number];
/** Each effect's period in seconds (ABI.md "Motion"). */
export const LOOP_PERIODS: Record<SceneLoopEffect, number> = {
  pulse: 1.2,
  breathe: 3,
  spin: 2,
  float: 3,
  wiggle: 0.6,
  bounce: 0.9,
  shimmer: 1.6,
};

/** `loop` as the attribute scene.css keys its keyframes on and the custom properties they read:
 * `--scene-loop-period` (seconds after ui.animationSpeed) and `--scene-loop-amount`. */
export function loopStyle(
  value: unknown,
  speed = 1,
): { effect: SceneLoopEffect; vars: Record<string, string> } | undefined {
  const loop = sceneRecord(value);
  const effect = loop.effect;
  if (typeof effect !== "string" || !(LOOP_EFFECTS as readonly string[]).includes(effect)) return undefined;
  const name = effect as SceneLoopEffect;
  const period = clamp(sceneNumber(loop.period) ?? LOOP_PERIODS[name], 0.05, 60) * speed;
  const amount = clamp(sceneNumber(loop.amount) ?? 1, -20, 20);
  return {
    effect: name,
    vars: {
      "--scene-loop-period": `${Math.round(period * 1000)}ms`,
      "--scene-loop-amount": String(amount),
      // Spin turns once per period; a negative amount turns the other way.
      "--scene-loop-turn": amount < 0 ? "-360deg" : "360deg",
    },
  };
}

export const TRANSITIONS = ["fade", "scale", "slide", "pop"] as const;
export type SceneTransition = (typeof TRANSITIONS)[number];
export const sceneTransition = (value: unknown): SceneTransition | undefined =>
  typeof value === "string" && (TRANSITIONS as readonly string[]).includes(value)
    ? (value as SceneTransition)
    : undefined;

/** A transition's keyframes and timing on entry (`exit` false) or removal (`exit` true). The
 * keyframes animate `transform` and `opacity`, which compose with the node's own `scale`, `rotate`
 * and `translate`; `opacity` ends at the node's own value. */
export function transitionAnimation(
  transition: SceneTransition,
  exit: boolean,
  opacity: number,
  env: SceneMotionEnv,
  doc?: Document,
): { keyframes: Keyframe[]; timing: SceneTiming } | null {
  const fadeTiming = sceneTiming("fade", env, doc);
  const timing = (motion: unknown) => sceneTiming(motion, env, doc);
  let hidden: Keyframe;
  let t: SceneTiming | null;
  switch (transition) {
    case "fade":
      hidden = { opacity: 0 };
      t = exit
        ? env.mode === "full"
          ? { duration: MOTION_FADES.fadeOut * env.speed, easing: MOTION_EASE_OUT }
          : null
        : fadeTiming;
      break;
    case "scale":
      hidden = { transform: "scale(0)" };
      t = timing(exit ? "disappear" : "appear");
      break;
    case "slide":
      hidden = { transform: exit ? "translateX(100%)" : "translateX(-100%)" };
      t = timing(exit ? "disappear" : "move");
      break;
    case "pop":
      hidden = { transform: "scale(0.6)", opacity: 0 };
      t = timing(exit ? "disappear" : "bouncy");
      break;
  }
  if (!t) return null;
  const shown: Keyframe = { transform: "none", opacity };
  if (!("opacity" in hidden)) delete shown.opacity;
  if (!("transform" in hidden)) delete shown.transform;
  return { keyframes: exit ? [shown, hidden] : [hidden, shown], timing: t };
}
