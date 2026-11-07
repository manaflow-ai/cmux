// A project's fold in All chats (Projects view) as one state transition on the settle (Leo, 2026-11-07:
// "they dont overshoot but they decelerate at the end. i think that might be the key"). The list is
// virtual: its rows are absolute boxes at a translateY each (ui/VirtualList.tsx), so the fold is the
// rows moving, not a box's height. On the click the rows drawn now are read where they are drawn (a
// fold still running included); after the change each row still drawn slides from there to its new
// place, every one on the same frames and curve:
// - Folding, the project's chats leave the list at once (its own rule: rows arrive and leave with no
//   motion, listMotion.ts), and what was drawn of them stays drawn as ghosts, inert and hidden from
//   assistive tech, over the list: they slide up into the header and fade out while the rows under it
//   rise into their places. The ghosts go on the frame the motion ends, so nothing is drawn after it.
// - Opening, the chats come out from under the header, fading in, while the rows under it slide down;
//   a chat whose ghost is still drawn (a fold cut short) comes back from where the ghost is.
// - A row that comes into the drawn range only now (it was past the list's end) moves by the same
//   shift as the rows under the header, so the block below moves as one.
// Cost: one read of the drawn rows before the change and one after, both bounded by the virtual
// window (never the whole list), and one Web Animation per drawn row that moves, which ends by itself
// (MOTION_SETTLE_MS). No observer and no frame loop. Under Reduce Motion, the pane's animations off or
// a hidden page (ui/motion/motionMode.ts) the fold is one frame and draws no ghost.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";

/// A drawn row of a project that folded away: where it was drawn, relative to the layer.
export interface FoldGhost<Row> {
  key: string;
  row: Row;
  top: number;
  height: number;
  opacity: number;
}

type Place = { top: number; height: number; opacity: number };
type Pending = { header: string; opening: boolean; members: ReadonlySet<string>; places: Map<string, Place> };

/// The attribute every drawn row (and ghost) carries: its key in the list.
export const FOLD_KEY = "data-fold-key";

function drawnPlaces(layer: HTMLElement): Map<string, Place> {
  const origin = layer.getBoundingClientRect().top;
  const view = layer.ownerDocument.defaultView;
  const places = new Map<string, Place>();
  for (const node of layer.querySelectorAll<HTMLElement>(`[${FOLD_KEY}]`)) {
    const rect = node.getBoundingClientRect();
    const opacity = Number.parseFloat(view?.getComputedStyle(node).opacity ?? "1");
    places.set(node.getAttribute(FOLD_KEY)!, {
      top: rect.top - origin,
      height: rect.height,
      opacity: Number.isFinite(opacity) ? opacity : 1,
    });
  }
  return places;
}

/// The fold of All chats' projects. `layer` holds the list and the ghosts (`.nt-all-scroll`).
export function useProjectFold<Row>(layer: RefObject<HTMLElement | null>, rowHeight: number) {
  const [ghosts, setGhosts] = useState<readonly FoldGhost<Row>[]>([]);
  const [turn, setTurn] = useState(0);
  const pending = useRef<Pending | undefined>(undefined);
  const running = useRef<Animation[]>([]);

  const stop = () => {
    const animations = running.current;
    running.current = [];
    for (const animation of animations) animation.cancel();
  };

  /// Folds (`opening` false) or opens the project whose header row is keyed `header`, its chats keyed
  /// and drawn from `members`, through `apply` (the owner's state change).
  const toggle = (
    header: string,
    opening: boolean,
    members: readonly { key: string; row: Row }[],
    apply: () => void,
  ) => {
    const root = layer.current;
    if (!root || motionMode(root.ownerDocument) !== "full" || typeof root.animate !== "function") {
      stop();
      setGhosts([]);
      apply();
      return;
    }
    const places = drawnPlaces(root);
    pending.current = { header, opening, members: new Set(members.map((member) => member.key)), places };
    setGhosts(
      opening
        ? []
        : members.flatMap(({ key, row }) => {
            const place = places.get(key);
            return place ? [{ key, row, ...place }] : [];
          }),
    );
    apply();
    setTurn((value) => value + 1);
  };

  useLayoutEffect(() => {
    const root = layer.current;
    const change = pending.current;
    pending.current = undefined;
    if (!root || !change) return;
    stop();
    const origin = root.getBoundingClientRect().top;
    const easing =
      root.ownerDocument.defaultView?.getComputedStyle(root).getPropertyValue("--cmux-ease-settle").trim() ||
      MOTION_SETTLE;
    const move = (node: HTMLElement, from: Keyframe, to: Keyframe, hold = false) => {
      const animation = node.animate([from, to], {
        duration: MOTION_SETTLE_MS,
        easing,
        fill: hold ? "forwards" : "none",
      });
      running.current.push(animation);
      return animation;
    };
    const nodes = [...root.querySelectorAll<HTMLElement>(`[${FOLD_KEY}]`)];
    const rows = nodes.filter((node) => !node.hasAttribute("data-fold-ghost"));
    const top = (node: HTMLElement) => node.getBoundingClientRect().top - origin;
    const headerNode = rows.find((node) => node.getAttribute(FOLD_KEY) === change.header);
    const headerTop = headerNode ? top(headerNode) : undefined;
    const headerWas = change.places.get(change.header);
    // What the rows under the header moved by: one that stayed says; else the project's chats' height.
    const below = (node: HTMLElement) => headerTop !== undefined && top(node) > headerTop;
    const stayed = rows.find(
      (node) =>
        below(node) &&
        !change.members.has(node.getAttribute(FOLD_KEY)!) &&
        change.places.has(node.getAttribute(FOLD_KEY)!),
    );
    const shift = stayed
      ? change.places.get(stayed.getAttribute(FOLD_KEY)!)!.top - top(stayed)
      : (change.opening ? -1 : 1) * change.members.size * rowHeight;
    for (const node of rows) {
      const key = node.getAttribute(FOLD_KEY)!;
      const base = node.style.transform;
      const now = top(node);
      const was = change.places.get(key);
      if (was) {
        const delta = was.top - now;
        const fade = was.opacity < 1;
        if (Math.abs(delta) > 0.5 || fade)
          move(
            node,
            { transform: `${base} translateY(${delta}px)`, ...(fade ? { opacity: was.opacity } : {}) },
            { transform: `${base} translateY(0px)`, ...(fade ? { opacity: 1 } : {}) },
          );
      } else if (change.opening && change.members.has(key)) {
        // Out from under the header, fading in.
        const from = (headerTop ?? now) - now;
        move(
          node,
          { transform: `${base} translateY(${from}px)`, opacity: 0 },
          { transform: `${base} translateY(0px)`, opacity: 1 },
        );
      } else if (below(node) && Math.abs(shift) > 0.5) {
        move(node, { transform: `${base} translateY(${shift}px)` }, { transform: `${base} translateY(0px)` });
      }
    }
    // The ghosts slide up into the header and fade; they go when the motion ends.
    const shown = nodes.filter((node) => node.hasAttribute("data-fold-ghost"));
    if (shown.length === 0) {
      if (!change.opening) setGhosts([]);
      return;
    }
    const into = headerTop ?? headerWas?.top ?? 0;
    let left = shown.length;
    for (const node of shown) {
      const at = change.places.get(node.getAttribute(FOLD_KEY)!);
      if (!at) continue;
      const base = node.style.transform;
      const animation = move(
        node,
        { transform: `${base} translateY(0px)`, opacity: at.opacity },
        { transform: `${base} translateY(${into - at.top}px)`, opacity: 0 },
        true,
      );
      animation.onfinish = () => {
        if (!running.current.includes(animation)) return;
        left -= 1;
        if (left === 0) setGhosts([]);
      };
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- one run per fold (`turn`); the rest is read from refs.
  }, [turn]);

  useLayoutEffect(() => stop, []);

  return { ghosts, toggle };
}
