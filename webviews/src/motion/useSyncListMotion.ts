// Draws the sync motion model (syncMotion.ts) on a DOM list. One hook per list:
//
//   const motion = useSyncListMotion(listRef, rows, { snapshot });
//   motion.items.map(({ row, exiting }) => <li data-sync-id={row.id} key={row.id}>…</li>)
//
// - Moves: FLIP. Each row's layout place (relative to the list, without its running slide) is
//   kept between commits; after a commit a row that changed place starts from where it is DRAWN
//   (old place plus the running slide) and springs to its new place on `move`. Only `transform`
//   animates, as Web Animations sampled from the spring, so the compositor runs it.
// - Inserts: the rows under it slide down to make room (their FLIP); the new row fades in on
//   `appear` where it lands.
// - Removals: the row leaves the flow at once (absolutely placed where it was), so the rows under
//   it slide up together, and it fades out on `disappear`; it unmounts when the fade ends.
// - Off screen: a row outside the list's scroll viewport both before and after does not animate; a
//   row entering or leaving the viewport starts or ends just past the visible edge, so a long jump
//   never streaks across the list.
// - Retarget: a change during a slide cancels it after reading the drawn transform; nothing jumps.
import { type RefObject, useLayoutEffect, useMemo, useRef, useState } from "react";
import { isAgentMotionOff } from "../agent-session/shared/motion";
import {
  planSyncChange,
  springSamples,
  SYNC_FADES,
  SYNC_SPRINGS,
  type SyncPlan,
  type SyncRow,
} from "./syncMotion";

type Place = { x: number; y: number; width: number; height: number };

export type SyncListItem<R extends SyncRow> = { row: R; exiting: boolean };

export type SyncListMotion<R extends SyncRow> = {
  /** The rows to draw, in order, with rows that are fading out still in place. */
  items: SyncListItem<R>[];
  /** The plan of the change this render draws. */
  plan: SyncPlan;
  /** Whether the row's rename crossfades in this render (SyncTitle `animate`). */
  renames(id: string): boolean;
};

export type SyncListOptions = {
  /** The change replaced the state (resync, reconnect, a gap): no motion. */
  snapshot?: boolean;
  /** This client's own direct manipulation, already on screen (SyncPlanInput.direct). */
  direct?: boolean;
  /** The element that scrolls the list (default: the nearest scrolling ancestor, else the list). */
  viewport?: RefObject<HTMLElement | null>;
};

function reducedMotion(): boolean {
  return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
}

function drawnShift(element: HTMLElement): { x: number; y: number } {
  const transform = getComputedStyle(element).transform;
  if (!transform || transform === "none") return { x: 0, y: 0 };
  const matrix = new DOMMatrixReadOnly(transform);
  return { x: matrix.m41, y: matrix.m42 };
}

function scrollerOf(element: HTMLElement): HTMLElement {
  for (let node: HTMLElement | null = element; node; node = node.parentElement) {
    const overflow = getComputedStyle(node).overflowY;
    if ((overflow === "auto" || overflow === "scroll") && node.scrollHeight > node.clientHeight) return node;
  }
  return element;
}

function rowsOf(root: HTMLElement): HTMLElement[] {
  return [...root.querySelectorAll<HTMLElement>("[data-sync-id]")].filter(
    (element) => element.closest("[data-sync-list]") === root,
  );
}

const spring = (key: keyof typeof SYNC_SPRINGS) => springSamples(SYNC_SPRINGS[key]);

export function useSyncListMotion<R extends SyncRow>(
  list: RefObject<HTMLElement | null>,
  rows: readonly R[],
  options: SyncListOptions = {},
): SyncListMotion<R> {
  // What the last commit drew: rows (for the plan) and layout places (for FLIP).
  const drawnRows = useRef<readonly R[] | undefined>(undefined);
  const places = useRef(new Map<string, Place>());
  const running = useRef(new Map<string, Animation>());
  // Rows fading out, with their place and index at removal.
  const [exiting, setExiting] = useState<ReadonlyMap<string, { row: R; index: number; place: Place }>>(new Map());
  const reduced = reducedMotion();
  const motionOff = isAgentMotionOff();
  const signature = rows.map((row) => `${row.id}\u0000${row.title}`).join("\u0001");

  // The plan is pure: what is drawn now against the new rows (rows off screen are filtered in
  // the layout pass, where they can be measured).
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- `rows` is represented by its signature.
  const plan = useMemo(
    () => planSyncChange({
        before: drawnRows.current,
        after: rows,
        snapshot: options.snapshot,
        direct: options.direct,
        reduced,
        motionOff,
      }),
    [signature, options.snapshot, options.direct, reduced, motionOff],
  );

  const items = useMemo(() => {
    const out: SyncListItem<R>[] = rows.map((row) => ({ row, exiting: false }));
    const live = new Set(rows.map((row) => row.id));
    for (const [id, gone] of [...exiting].sort((a, b) => a[1].index - b[1].index))
      if (!live.has(id)) out.splice(Math.min(gone.index, out.length), 0, { row: gone.row, exiting: true });
    return out;
  }, [rows, exiting]);

  const drawnPlan = useRef<SyncPlan | undefined>(undefined);
  useLayoutEffect(() => {
    const root = list.current;
    if (!root) return;
    if (getComputedStyle(root).position === "static") root.style.position = "relative";
    const elements = new Map(rowsOf(root).map((element) => [element.dataset.syncId ?? "", element] as const));
    // A render that only adds or drops a fading row (the exit state) starts its fade and nothing
    // else: the slides of the change itself keep running.
    if (drawnPlan.current === plan) {
      startExits(elements);
      return;
    }
    drawnPlan.current = plan;
    const previousRows = drawnRows.current;
    drawnRows.current = rows;
    const viewport = options.viewport?.current ?? scrollerOf(root);
    const origin = root.getBoundingClientRect();
    const clip = viewport.getBoundingClientRect();
    // Reads first: drawn shifts, then layout places (drawn box less its running slide).
    const shifts = new Map([...elements].map(([id, element]) => [id, drawnShift(element)] as const));
    const after = new Map<string, Place>();
    for (const [id, element] of elements) {
      if (element.dataset.syncExiting === "true") continue;
      const rect = element.getBoundingClientRect();
      const shift = shifts.get(id) ?? { x: 0, y: 0 };
      after.set(id, {
        x: rect.left - origin.left - shift.x,
        y: rect.top - origin.top - shift.y,
        width: rect.width,
        height: rect.height,
      });
    }
    for (const [id, animation] of running.current) {
      if (elements.get(id)?.dataset.syncExiting === "true") continue;
      animation.cancel();
      running.current.delete(id);
    }
    const before = places.current;
    places.current = after;
    const onScreen = (place: Place | undefined) =>
      place !== undefined && origin.top + place.y + place.height > clip.top && origin.top + place.y < clip.bottom;
    const animates = new Set(plan.rows.filter((row) => row.animate).map((row) => row.id));

    // Removals: hold the row where it was and fade it out (or drop it at once).
    if (previousRows) {
      const leaving = new Map<string, { row: R; index: number; place: Place }>();
      for (const planned of plan.rows) {
        if (!planned.kinds.includes("remove")) continue;
        const index = previousRows.findIndex((row) => row.id === planned.id);
        const place = before.get(planned.id);
        if (index >= 0 && place && animates.has(planned.id) && onScreen(place))
          leaving.set(planned.id, { row: previousRows[index], index, place });
      }
      if (leaving.size > 0) setExiting((current) => new Map([...current, ...leaving]));
    }
    if (plan.still !== undefined || reduced || motionOff) return;

    // Moves and pushes: every surviving row that changed place slides from where it is drawn.
    const move = spring("move");
    for (const [id, is] of after) {
      const element = elements.get(id);
      const was = before.get(id);
      if (!element) continue;
      if (!was) {
        if (animates.has(id) && onScreen(is))
          track(
            id,
            element.animate([{ opacity: 0 }, { opacity: 1 }], { duration: SYNC_FADES.fadeIn, easing: "ease-out" }),
          );
        continue;
      }
      const shift = shifts.get(id) ?? { x: 0, y: 0 };
      let dy = was.y + shift.y - is.y;
      const dx = was.x + shift.x - is.x;
      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) continue;
      const seenBefore = onScreen({ ...was, y: was.y + shift.y });
      if (!seenBefore && !onScreen(is)) continue;
      // Entering from off screen: start just past the visible edge.
      if (!seenBefore) {
        const top = clip.top - origin.top;
        const bottom = clip.bottom - origin.top;
        dy = was.y < top ? top - is.height - is.y : bottom - is.y;
      }
      const frames = move.progress.map((value, index) => ({
        offset: index / (move.progress.length - 1),
        transform: `translate(${(dx * (1 - value)).toFixed(2)}px, ${(dy * (1 - value)).toFixed(2)}px)`,
      }));
      track(id, element.animate(frames, { duration: move.durationMs }));
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `rows` is represented by `plan`.
  }, [list, plan, items]);

  function track(id: string, animation: Animation) {
    running.current.set(id, animation);
    const done = () => {
      if (running.current.get(id) === animation) running.current.delete(id);
    };
    animation.onfinish = done;
    animation.oncancel = done;
  }

  function startExits(elements: Map<string, HTMLElement>) {
    for (const [id, element] of elements) {
      const gone = exiting.get(id);
      if (element.dataset.syncExiting !== "true" || !gone || running.current.has(id)) continue;
      Object.assign(element.style, {
        position: "absolute",
        left: `${gone.place.x}px`,
        top: `${gone.place.y}px`,
        width: `${gone.place.width}px`,
        pointerEvents: "none",
      });
      const fade = element.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: spring("disappear").durationMs,
        easing: "ease-out",
        fill: "forwards",
      });
      track(id, fade);
      fade.onfinish = () => {
        running.current.delete(id);
        setExiting((current) => {
          const next = new Map(current);
          next.delete(id);
          return next;
        });
      };
    }
  }

  useLayoutEffect(
    () => () => {
      for (const animation of running.current.values()) animation.cancel();
    },
    [],
  );

  const renameSet = useMemo(
    () => new Set(plan.rows.filter((row) => row.animate && row.kinds.includes("rename")).map((row) => row.id)),
    [plan],
  );
  return { items, plan, renames: (id) => renameSet.has(id) };
}
