// How much a primitive in ui/motion may move right now. One reading for every primitive here, so a
// sliding indicator, a view swap and the depth layer agree: the host's motion switch
// (`data-agent-motion` / `data-cmux-motion` on the root, a zero `--agent-motion-in` token), Reduce
// Motion, and a hidden page. Given the `node` that moves, also a chat's minimal motion under load
// (`data-chat-motion="minimal"` on the chat over it, agent-session/acpmux/conversation/frameBudget.ts):
// the chat's own motion stops, and the rest of the page (a view swap, the sidebar, depth) moves on.

import { motionToken } from "./motionTokens";

export type MotionMode = "full" | "reduced" | "none";

/** "none": animations are off or the page is hidden; "reduced": Reduce Motion; else "full". */
export function motionMode(
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
  node?: Element | null,
): MotionMode {
  const root = doc?.documentElement;
  const view = doc?.defaultView;
  if (!doc || !root || !view) return "none";
  if (doc.visibilityState === "hidden") return "none";
  if (root.dataset.agentMotion === "off" || root.dataset.cmuxMotion === "off") return "none";
  // A chat that missed its frame budget moves nothing of its own until its frames are healthy again.
  if (node?.closest('[data-chat-motion="minimal"]')) return "none";
  // Kept per page and theme (motionTokens.ts): a read here after a commit's writes recalculated the page's style.
  const token = motionToken(root, "--agent-motion-in", doc);
  if (token && !(Number.parseFloat(token) > 0)) return "none";
  if (root.dataset.agentMotion === "reduced" || root.dataset.cmuxMotion === "reduced") return "reduced";
  if (reducedQuery(view)?.matches) return "reduced";
  return "full";
}

/// One `prefers-reduced-motion` query per window, kept: `matches` follows the setting live, and a new
/// query each call (a live line's every change, ThinkingLine's dwell) built a MediaQueryList each time.
/// Kept with the `matchMedia` it came from, so a window given another one (a test's stand-in) asks it.
const reducedQueries = new WeakMap<Window, { from: Window["matchMedia"]; query: MediaQueryList | null }>();
function reducedQuery(view: Window): MediaQueryList | null {
  const from = view.matchMedia;
  if (typeof from !== "function") return null;
  const kept = reducedQueries.get(view);
  if (kept && kept.from === from) return kept.query;
  const query = from.call(view, "(prefers-reduced-motion: reduce)") ?? null;
  reducedQueries.set(view, { from, query });
  return query;
}

/**
 * The one spring as a Web Animations easing, or the ease-out where the engine has no `linear()`
 * easing (WebKit before Safari 17.2, which macOS 14.0 and 14.1 ship): there `animate()` throws on it.
 */
export function springEasing(
  spring: string,
  fallback: string,
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
): string {
  const supports = (doc?.defaultView as (Window & typeof globalThis) | null | undefined)?.CSS?.supports;
  try {
    return supports?.("transition-timing-function", spring) ? spring : fallback;
  } catch {
    return fallback;
  }
}
