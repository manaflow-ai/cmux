// Scene motion: the host side of the scene DSL's `transition`, `contentTransition` and
// `animation` props, so an extension animates a change with no timer of its own. A node with a
// `transition` fades, slides, scales or moves in when a render adds it (never on the first
// scene) and out when a render removes it: its parent keeps drawing the removed node, from its
// last props, until it has left. CSS draws every movement (scene.css) behind the motion gate:
// WebTheme's `data-cmux-motion` off draws the end state at once; reduced (Reduce Motion, calm
// motion) turns each movement into a crossfade.
import { createContext, useContext, useEffect, useReducer, useRef, useState, type ReactNode } from "react";
import type { SceneNode, SceneStore } from "./store";

/** How long a removed node stays to leave; scene.css's leave animations match it. */
export const SCENE_LEAVE_MS = 240;

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

/** True once the scene's first frame is drawn: nodes added after it animate in. */
export const SceneAppearedContext = createContext<{ current: boolean }>({ current: true });
/** True inside a node that is leaving: its subtree keeps drawing from its last props. */
export const SceneLeavingContext = createContext(false);

export function SceneAppeared({ children }: { children: ReactNode }) {
  const appeared = useRef(false);
  useEffect(() => {
    appeared.current = true;
  }, []);
  return <SceneAppearedContext.Provider value={appeared}>{children}</SceneAppearedContext.Provider>;
}

/** Whether the node animates in: it has a transition and came after the first frame. */
export function useSceneEntering(node: SceneNode | undefined): boolean {
  const appeared = useContext(SceneAppearedContext);
  const [entering] = useState(() => appeared.current && typeof node?.props.transition === "string");
  return entering;
}

export type SceneChild = { id: string; leaving: boolean };

/**
 * The children to draw: the node's own, plus each child a render just removed that has a
 * `transition`, kept at its old place for SCENE_LEAVE_MS (none while motion is off).
 */
export function useSceneChildren(store: SceneStore, ids: readonly string[]): SceneChild[] {
  // Worked out in render, not in an effect: a removed child keeps its component (same key, same
  // render), so it can still draw its last props while it leaves.
  const state = useRef({
    previous: ids,
    transitions: new Map<string, boolean>(),
    leaving: new Map<string, number>(),
    scheduled: new Set<string>(),
  });
  const [, redraw] = useReducer((n: number) => n + 1, 0);
  const timers = useRef(new Set<ReturnType<typeof setTimeout>>());
  const s = state.current;
  if (s.previous !== ids) {
    const before = s.previous;
    s.previous = ids;
    const live = new Set(ids);
    const motion = sceneMotion();
    before.forEach((id, index) => {
      if (live.has(id)) return;
      if (motion !== "off" && s.transitions.get(id) === true) s.leaving.set(id, index);
      else s.transitions.delete(id);
    });
    for (const id of ids) {
      s.leaving.delete(id);
      s.scheduled.delete(id);
    }
  }
  // Each live child's transition, noted while it is still in the store.
  for (const id of ids) s.transitions.set(id, typeof store.getNode(id)?.props.transition === "string");

  useEffect(() => {
    for (const id of s.leaving.keys()) {
      if (s.scheduled.has(id)) continue;
      s.scheduled.add(id);
      const timer = setTimeout(() => {
        timers.current.delete(timer);
        if (!s.scheduled.delete(id)) return;
        s.leaving.delete(id);
        s.transitions.delete(id);
        redraw();
      }, SCENE_LEAVE_MS);
      timers.current.add(timer);
    }
  });
  useEffect(() => {
    const pending = timers.current;
    return () => {
      for (const timer of pending) clearTimeout(timer);
    };
  }, []);

  if (!s.leaving.size) return ids.map((id) => ({ id, leaving: false }));
  const out: SceneChild[] = ids.map((id) => ({ id, leaving: false }));
  for (const [id, at] of [...s.leaving].sort((a, b) => a[1] - b[1])) {
    out.splice(Math.min(at, out.length), 0, { id, leaving: true });
  }
  return out;
}

/**
 * A Text's content under `contentTransition`: `numericText` rolls each changed character in
 * (aligned from the end, as digits are), up when the number grew and down when it shrank;
 * `opacity` crossfades the whole text. Nothing rolls on the first draw.
 */
export function SceneTextContent({ text, transition }: { text: string; transition: unknown }) {
  const previous = useRef<string | undefined>(undefined);
  const before = previous.current;
  useEffect(() => {
    previous.current = text;
  }, [text]);
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
  const chars = [...text];
  const old = [...(before ?? "")];
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
