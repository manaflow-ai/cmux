// The app areas a change belongs to (whats-new lane, 2026-10-20): the Updated card names one line
// per area ("Sidebar: …", updateSummary.ts) and What's New lists an update's changes under them.
// Pure: no DOM, no state.
import { changeArea, readableChange } from "./readableChange";

/** The areas people know, in the order a title is matched: the first that matches names it
    (`updates.area.<key>`). A subject's own area label ("cmux-next sidebar: …") is matched first. */
export const AREAS = [
  ["sidebar", /\b(?:sidebar|workspace groups?)\b/i],
  ["newTab", /\bnew tab\b/i],
  ["composer", /\b(?:composer|dictation)\b/i],
  ["agentChat", /\b(?:agents?|agent chat|agent pane|transcript|chats?|sub-sessions?)\b/i],
  ["home", /\b(?:home|chief)\b/i],
  ["tabs", /\b(?:tabs?|tab row)\b/i],
  ["terminal", /\b(?:terminals?|shell|scrollback)\b/i],
  ["browser", /\bbrowser\b/i],
  ["palette", /\b(?:command )?palette\b/i],
  ["settings", /\bsettings?\b/i],
  ["updates", /\b(?:update card|updated card|restart to update|what's new|roll back)\b/i],
  ["keyboard", /\b(?:shortcuts?|keys)\b/i],
  ["panes", /\b(?:panes?|splits?)\b/i],
  ["windows", /\bwindows?\b/i],
] as const;

export type AreaKey = (typeof AREAS)[number][0];

/** The area a title (or, first, its subject's area label) names, else undefined. */
export function areaOf(title: string, label?: string): AreaKey | undefined {
  for (const text of [label, title]) {
    const hit = text ? AREAS.find(([, pattern]) => pattern.test(text)) : undefined;
    if (hit) return hit[0];
  }
  return undefined;
}

/** The area of a commit subject: its own label, else what its readable title names. */
export function subjectArea(subject: string): AreaKey | undefined {
  return areaOf(readableChange(subject).title, changeArea(subject));
}

/** Changes in runs of one area: named areas first, the one with most changes first (ties keep
    the order they appear in), and the changes no area names last. */
export function byArea<T extends { area?: AreaKey }>(changes: T[]): { area?: AreaKey; items: T[] }[] {
  const groups = new Map<AreaKey | undefined, { area?: AreaKey; items: T[]; first: number }>();
  changes.forEach((change, index) => {
    const group = groups.get(change.area) ?? { area: change.area, items: [], first: index };
    group.items.push(change);
    groups.set(change.area, group);
  });
  return [...groups.values()]
    .sort((a, b) => Number(!a.area) - Number(!b.area) || b.items.length - a.items.length || a.first - b.first)
    .map(({ area, items }) => ({ area, items }));
}
