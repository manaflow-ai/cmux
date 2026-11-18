// Runs a scene node's declared motion on its element (cmux-app-host js/ABI.md "Motion"): value
// animations from the value on screen when an animatable prop changes, and the enter and exit of
// its `transition`. Each is one Web Animation started in a layout effect after the commit that
// changed the prop, so the browser (Core Animation in WebKit) runs every frame and React renders
// once per change, never per frame.
import { useLayoutEffect, useRef, type RefObject } from "react";
import {
  sceneMotionEnv,
  sceneTiming,
  sceneTransition,
  transitionAnimation,
  type SceneMotionEnv,
  type SceneTiming,
} from "./motionProps";
import { sceneNumber, sceneRecord } from "./sceneStyle";
import type { SceneNode, SceneProps, SceneStore } from "./store";

/** The computed property read, and the keyframe property it animates (border colors read one side). */
const KEYFRAME_NAME: Record<string, string> = {
  "background-color": "backgroundColor",
  "border-top-color": "borderColor",
  "stroke-dasharray": "strokeDasharray",
  "stroke-dashoffset": "strokeDashoffset",
};

/** Every computed property a node's own element may animate. */
const TRACKED = [
  "opacity",
  "rotate",
  "scale",
  "translate",
  "filter",
  "width",
  "height",
  "color",
  "background-color",
  "border-top-color",
] as const;

/** The element's computed properties each animatable prop drives. */
export function animatedProperties(props: SceneProps): string[] {
  const out: string[] = [];
  // `breathe` runs opacity itself.
  if (props.opacity !== undefined && sceneRecord(props.loop).effect !== "breathe") out.push("opacity");
  if (props.rotation !== undefined) out.push("rotate");
  if (props.scale !== undefined) out.push("scale");
  if (props.offset !== undefined) out.push("translate");
  if (props.blur !== undefined || props.glow !== undefined) out.push("filter");
  const frame = sceneRecord(props.frame);
  if (sceneNumber(frame.width) !== undefined) out.push("width");
  if (sceneNumber(frame.height) !== undefined) out.push("height");
  if (props.color !== undefined) out.push("color");
  if (props.fill !== undefined || props.background !== undefined) out.push("background-color");
  if (props.borderColor !== undefined || props.stroke !== undefined) out.push("border-top-color");
  return out;
}

/** Whether two computed `filter` lists interpolate (the same functions in the same order, or none). */
export function filtersMatch(a: string, b: string): boolean {
  const names = (value: string) => (value === "none" || !value ? "" : (value.match(/[a-z-]+\(/g) ?? []).join(""));
  const left = names(a);
  const right = names(b);
  return left === right || left === "" || right === "";
}

function read(element: Element, properties: readonly string[]): Record<string, string> {
  const view = element.ownerDocument.defaultView;
  const out: Record<string, string> = {};
  if (!view) return out;
  const style = view.getComputedStyle(element);
  for (const property of properties) out[property] = style.getPropertyValue(property);
  return out;
}

const canAnimate = (element: Element | null | undefined): element is Element =>
  !!element && typeof (element as Element & { animate?: unknown }).animate === "function";

/** One element's value animation: where its props were at the last commit, and the animation in flight. */
export class MotionTrack {
  private target: Record<string, string> | null = null;
  private running: Animation | null = null;
  private runningProps: string[] = [];

  /** After a commit: animate each of `properties` that changed from where it is on screen to its
   * new value. `tracked` is every property the element may animate, read on each commit so a
   * property the app sets for the first time starts from the value it had. */
  update(
    element: Element | null | undefined,
    properties: readonly string[],
    timing: SceneTiming | null,
    tracked: readonly string[] = properties,
  ): void {
    if (!canAnimate(element) || tracked.length === 0) {
      this.cancel();
      this.target = null;
      return;
    }
    let before = this.target;
    // Mid-flight: the animated properties start from their in-flight values (a retarget).
    if (this.running && this.running.playState !== "finished" && this.running.playState !== "idle") {
      before = { ...before, ...read(element, this.runningProps) };
    }
    this.cancel();
    const target = read(element, tracked);
    this.target = target;
    if (!before || !timing || !(timing.duration > 0)) return;
    const from: Record<string, string> = {};
    const to: Record<string, string> = {};
    const moved: string[] = [];
    for (const property of properties) {
      const a = before[property];
      const b = target[property];
      if (a === undefined || b === undefined || a === b || a === "" || b === "") continue;
      if (property === "filter" && !filtersMatch(a, b)) continue;
      const name = KEYFRAME_NAME[property] ?? property;
      from[name] = a;
      to[name] = b;
      moved.push(property);
    }
    if (moved.length === 0) return;
    const animation = element.animate([from, to], { duration: timing.duration, easing: timing.easing });
    this.running = animation;
    this.runningProps = moved;
    animation.onfinish = () => {
      if (this.running === animation) this.running = null;
    };
  }

  cancel(): void {
    this.running?.cancel();
    this.running = null;
    this.runningProps = [];
  }
}

// The scene's motion switch and speed, read at most every 250 ms (a batch of node commits shares one read).
let cachedEnv: { doc: Document; at: number; env: SceneMotionEnv } | undefined;
const ENV_TTL_MS = 250;
export function currentMotionEnv(
  doc: Document,
  now = typeof performance === "undefined" ? Date.now() : performance.now(),
): SceneMotionEnv {
  if (cachedEnv && cachedEnv.doc === doc && now - cachedEnv.at < ENV_TTL_MS) return cachedEnv.env;
  const env = sceneMotionEnv(doc);
  cachedEnv = { doc, at: now, env };
  return env;
}
/** Tests switch motion mid-file. */
export const resetMotionEnvCache = () => {
  cachedEnv = undefined;
};

/** A node's part that moves on its own element: a trimmed shape's outline, an animated progress fill. */
export type MotionPart = { ref: RefObject<Element | null>; properties: readonly string[] };

type MotionState = {
  track: MotionTrack;
  partTrack: MotionTrack;
  entered: boolean;
  exiting: boolean;
  transition: Animation | null;
  props: SceneProps | null;
};

const newMotionState = (): MotionState => ({
  track: new MotionTrack(),
  partTrack: new MotionTrack(),
  entered: false,
  exiting: false,
  transition: null,
  props: null,
});

export function useSceneMotion(
  ref: RefObject<HTMLElement | null>,
  node: SceneNode | undefined,
  store: SceneStore,
  part?: MotionPart,
): void {
  // One mutable record per mounted node, made in its first effect (nothing reads or writes it in render).
  const state = useRef<MotionState | null>(null);

  useLayoutEffect(() => {
    if (!state.current) state.current = newMotionState();
    const s = state.current;
    const element = ref.current;
    if (!node || !element) return;
    const doc = element.ownerDocument;
    const env = currentMotionEnv(doc);
    const transition = sceneTransition(node.props.transition);

    if (node.exiting) {
      if (s.exiting) return;
      s.exiting = true;
      s.track.cancel();
      s.partTrack.cancel();
      s.transition?.cancel();
      const opacity = Number.parseFloat(doc.defaultView?.getComputedStyle(element).opacity ?? "1");
      const exit =
        transition && canAnimate(element)
          ? transitionAnimation(transition, true, Number.isFinite(opacity) ? opacity : 1, env, doc)
          : null;
      const finish = () => store.finishExit(node.id);
      if (!exit) {
        queueMicrotask(finish);
        return;
      }
      const animation = element.animate(exit.keyframes, {
        duration: exit.timing.duration,
        easing: exit.timing.easing,
        fill: "forwards",
      });
      s.transition = animation;
      animation.onfinish = finish;
      animation.oncancel = finish;
      return;
    }

    const animated = node.props.animation !== undefined && node.props.animation !== null;
    if (animated) {
      const timing = sceneTiming(node.props.animation, env, doc);
      // A prop the app just cleared (a glow set to null) animates back too.
      const properties = [...new Set([...animatedProperties(s.props ?? {}), ...animatedProperties(node.props)])];
      s.track.update(element, properties, timing, TRACKED);
      if (part) s.partTrack.update(part.ref.current, part.properties, timing);
    } else {
      s.track.update(null, [], null);
      s.partTrack.update(null, [], null);
    }
    s.props = node.props;

    if (!s.entered) {
      s.entered = true;
      if (transition && canAnimate(element)) {
        const opacity = Number.parseFloat(doc.defaultView?.getComputedStyle(element).opacity ?? "1");
        const enter = transitionAnimation(transition, false, Number.isFinite(opacity) ? opacity : 1, env, doc);
        if (enter) {
          s.transition = element.animate(enter.keyframes, {
            duration: enter.timing.duration,
            easing: enter.timing.easing,
          });
        }
      }
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- a node snapshot is immutable: a new one is the only change; the refs and store are fixed
  }, [node]);

  useLayoutEffect(
    () => () => {
      state.current?.track.cancel();
      state.current?.partTrack.cancel();
    },
    [],
  );
}
