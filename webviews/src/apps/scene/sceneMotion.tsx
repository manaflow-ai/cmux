// Scene motion: the host side of the scene DSL's `transition`, `contentTransition` and
// `animation` props, so an extension animates a change with no timer of its own. A node with a
// `transition` fades, slides, scales or moves in when a render adds it (never on the first
// scene) and out when a render removes it: its parent keeps drawing the removed node, from its
// last props, until it has left. CSS draws every movement (scene.css) behind the motion gate:
// WebTheme's `data-cmux-motion` off draws the end state at once; reduced (Reduce Motion, calm
// motion) turns each movement into a crossfade.
import { createContext, useEffect, useState, type ReactNode } from "react";
import { MOTION_MS } from "../../motion/scale.generated";
import type { SceneNode, SceneStore } from "./store";

/** How long a removed node stays to leave: the motion scale's `quick` step, as scene.css's leave animations. */
export const SCENE_LEAVE_MS = MOTION_MS.quick;

/** The leave's length now: `--cmux-motion-quick` as the page computes it (ui.animationSpeed scales it). */
function leaveMs(): number {
  try {
    const value = getComputedStyle(document.documentElement).getPropertyValue("--cmux-motion-quick").trim();
    const number = Number.parseFloat(value);
    if (!Number.isFinite(number) || number < 0) return SCENE_LEAVE_MS;
    return value.endsWith("ms") ? number : value.endsWith("s") ? number * 1000 : number;
  } catch {
    return SCENE_LEAVE_MS;
  }
}

export type SceneMotion = "full" | "reduced" | "off";

/** The motion gate: the app's (`data-cmux-motion`, `data-agent-motion`), then the system's Reduce Motion. */
export function sceneMotion(): SceneMotion {
  if (typeof document === "undefined") return "full";
  const root = document.documentElement.dataset;
  if (root.cmuxMotion === "off" || root.agentMotion === "off") return "off";
  if (root.cmuxMotion === "reduced" || root.agentMotion === "reduced") return "reduced";
  try {
    if (globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true) return "reduced";
  } catch {
    // No media queries: full motion.
  }
  return "full";
}

/** True inside a node that is leaving: its subtree keeps drawing from its last props. */
export const SceneLeavingContext = createContext(false);

/**
 * Marks the scene's first frame drawn once it commits (per reset generation, which keys it):
 * nodes added after it animate in. The store holds the mark, so no node rerenders for it.
 */
export function SceneAppeared({
  store,
  generation,
  children,
}: {
  store: SceneStore;
  generation: number;
  children: ReactNode;
}) {
  useEffect(() => store.markDrawn(generation), [store, generation]);
  return <>{children}</>;
}

/** Whether the node animates in: it has a transition and came after the first frame. */
export function useSceneEntering(store: SceneStore, node: SceneNode | undefined): boolean {
  const [entering] = useState(() => store.hasDrawn() && typeof node?.props.transition === "string");
  return entering;
}

export type SceneChild = { id: string; leaving: boolean };

type Seen = { ids: readonly string[]; leaving: ReadonlyMap<string, number> };
const NONE_LEAVING: ReadonlyMap<string, number> = new Map();

/**
 * The children to draw: the node's own, plus each child a render just removed that has a
 * `transition` (the store keeps its last props as departed), kept at its old place for the
 * motion scale's quick step (none while motion is off).
 */
export function useSceneChildren(store: SceneStore, ids: readonly string[]): SceneChild[] {
  // Worked out in render from the previous render's state (React's "storing information from
  // previous renders"), so a removed child keeps its component and draws its last props.
  const [seen, setSeen] = useState<Seen>(() => ({ ids, leaving: NONE_LEAVING }));
  let current = seen;
  if (seen.ids !== ids) {
    const live = new Set(ids);
    const leaving = new Map([...seen.leaving].filter(([id]) => !live.has(id)));
    if (sceneMotion() !== "off") {
      seen.ids.forEach((id, index) => {
        if (!live.has(id) && store.getDeparted(id)) leaving.set(id, index);
      });
    }
    current = { ids, leaving: leaving.size ? leaving : NONE_LEAVING };
    setSeen(current);
  }

  // One timer for the leaving set: every leave lasts the same quick step, so the set leaves together.
  // A set that changes (one more leaves, or one comes back) replaces the timer, so a child that comes
  // back is never dropped, and leaving again starts a fresh leave.
  const leavingNow = current.leaving;
  useEffect(() => {
    if (!leavingNow.size) return undefined;
    const timer = setTimeout(() => {
      for (const id of leavingNow.keys()) store.forgetDeparted(id);
      setSeen((previous) => {
        const leaving = new Map([...previous.leaving].filter(([id]) => !leavingNow.has(id)));
        return { ...previous, leaving: leaving.size ? leaving : NONE_LEAVING };
      });
    }, leaveMs());
    return () => clearTimeout(timer);
  }, [leavingNow, store]);

  const out: SceneChild[] = ids.map((id) => ({ id, leaving: false }));
  if (!leavingNow.size) return out;
  for (const [id, at] of [...leavingNow].sort((a, b) => a[1] - b[1])) {
    out.splice(Math.min(at, out.length), 0, { id, leaving: true });
  }
  return out;
}

/** `text`'s user-perceived characters (an emoji or accented letter stays whole). */
function graphemes(text: string): string[] {
  const Segmenter = (globalThis as { Intl?: typeof Intl }).Intl?.Segmenter;
  if (typeof Segmenter === "function") {
    return Array.from(new Segmenter(undefined, { granularity: "grapheme" }).segment(text), (part) => part.segment);
  }
  return Array.from(text);
}

/**
 * A Text's content under `contentTransition`: `numericText` rolls each changed character in
 * (aligned from the end, as digits are), up when the number grew and down when it shrank;
 * `opacity` crossfades the whole text. Nothing rolls on the first draw.
 */
export function SceneTextContent({ text, transition }: { text: string; transition: unknown }) {
  // The text before the last change, kept in state so a rerender with the same text keeps its roll.
  const [shown, setShown] = useState<{ text: string; before: string | undefined }>(() => ({ text, before: undefined }));
  let current = shown;
  if (shown.text !== text) {
    current = { text, before: shown.text };
    setShown(current);
  }
  const before = current.before;
  if (transition !== "numericText" && transition !== "opacity") return <>{text}</>;
  const changed = before !== undefined && before !== text;
  if (transition === "opacity") {
    return (
      <span key={text} className="cmux-app-scene-content" data-roll={changed ? "fade" : undefined}>
        {text}
      </span>
    );
  }
  const direction = changed && numberOf(text) < numberOf(before ?? "") ? "down" : "up";
  const chars = graphemes(text);
  const old = graphemes(before ?? "");
  return (
    <>
      {chars.map((char, index) => {
        const fromEnd = chars.length - 1 - index;
        const rolled = changed && old[old.length - 1 - fromEnd] !== char;
        return (
          <span key={`${fromEnd}:${char}`} className="cmux-app-scene-digit" data-roll={rolled ? direction : undefined}>
            {char}
          </span>
        );
      })}
    </>
  );
}

function numberOf(text: string): number {
  const value = Number.parseFloat(text.replace(/[^\d.-]/g, ""));
  return Number.isFinite(value) ? value : 0;
}
