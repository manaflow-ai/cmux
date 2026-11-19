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

/** `bouncy` (the one token that overshoots, for playful reveals): the contract's own spring. `smooth` and
 * `snappy` are the motion scale's CSS steps (scene.css), not springs. */
export const SCENE_SPRINGS = {
  ...MOTION_SPRINGS,
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
