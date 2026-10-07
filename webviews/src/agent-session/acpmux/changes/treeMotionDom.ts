// Applies the changes tree's disclosure motion (treeMotion.ts) to a Pierre file tree. Pierre owns
// the rows (a Preact render in an open shadow root, rows reused by slot) and swaps a folder's rows
// in or out at once; this layer watches that and draws the motion over the final layout:
//   1. a snapshot holds each rendered row's layout place and a copy of it: taken in the frame after
//      any change of rows while nothing moves, and by every plan (no event listeners: a click, a
//      key, or a reveal from the diff all reach the tree the same way, through Pierre);
//   2. when Pierre's mutation lands (a MutationObserver, before the next paint), the folder whose
//      aria-expanded changed starts (or reverses) its motion; rows that left the DOM but must stay
//      visible become ghosts (their copies, in a layer of the scrolled list);
//   3. every rendered row and ghost gets one Web Animation (transform, opacity, clip-path; never a
//      layout property) sampled from the same openness curve, so rows and chevrons stay in sync.
// Planning reads layout once (all reads, then all writes) and is reported as the performance
// measure `cmux-motion:tree-plan`. Any other change of rows (a scroll, a filter) while a motion
// runs plans again from the same curves; a change with no motion running does nothing.
import {
  effectiveArm,
  rowKeyframes,
  rowVisual,
  sampleTimes,
  snapKeyframes,
  startFolder,
  travelFor,
  relation,
  type ArmMotion,
  type FolderMotion,
  type TreeArm,
} from "./treeMotion";

type Snapshot = {
  time: number;
  /** The list's height: what the toggle changes it by is the folder's block height. */
  height: number;
  /** Each rendered row (and ghost): its path, layout place in list coordinates, copy. */
  rows: Map<string, { top: number; height: number; expanded: string | null; copy: HTMLElement }>;
};

type Ghost = { path: string; top: number; height: number; element: HTMLElement };

const ROWS = '[data-type="item"]:not([data-item-parked]):not([data-file-tree-sticky-row])';
const CHEVRON = '[data-icon-name="file-tree-icon-chevron"]';

const reducedMotion = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;

/**
 * Starts the motion of `arm` on the tree inside `container` (the element around Pierre's host).
 * Returns the cleanup. Arm a (today's instant layout) attaches nothing.
 */
export function attachTreeMotion(container: HTMLElement, arm: TreeArm): () => void {
  if (arm === "a") return () => {};
  let shadow: ShadowRoot | null = null;
  let observer: MutationObserver | null = null;
  let snapshot: Snapshot | null = null;
  let folders: FolderMotion[] = [];
  let ghosts: Ghost[] = [];
  let layer: HTMLElement | null = null;
  let animations: Animation[] = [];
  let generation = 0;
  let snapshotFrame = 0;

  const list = () => shadow?.querySelector<HTMLElement>('[data-file-tree-virtualized-list="true"]') ?? null;
  const scroller = () => shadow?.querySelector<HTMLElement>('[data-file-tree-virtualized-scroll="true"]') ?? null;
  const liveRows = () =>
    [...(shadow?.querySelectorAll<HTMLElement>(ROWS) ?? [])].filter((row) => !layer?.contains(row));

  const connect = () => {
    if (shadow) return true;
    const host = container.querySelector<HTMLElement>("*");
    if (!host?.shadowRoot) return false;
    shadow = host.shadowRoot;
    observer = new MutationObserver(onMutations);
    observer.observe(shadow, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["aria-expanded", "data-item-path"],
    });
    return true;
  };

  /** A ghost is a picture of the row (in an aria-hidden layer): not a tree item, not focusable, no
   * duplicate id. aria-expanded stays: the chevron's angle is styled from it. */
  const copyOf = (row: HTMLElement) => {
    const copy = row.cloneNode(true) as HTMLElement;
    for (const attribute of ["role", "id", "tabindex"]) copy.removeAttribute(attribute);
    return copy;
  };

  /** The snapshot of rows at their layout places (`rows` read with no motion applied). */
  const record = (
    listElement: HTMLElement,
    rows: { element: HTMLElement; path: string; top: number; height: number }[],
  ) => {
    const map: Snapshot["rows"] = new Map();
    for (const row of rows)
      map.set(row.path, {
        top: row.top,
        height: row.height,
        expanded: row.element.getAttribute("aria-expanded"),
        copy: copyOf(row.element),
      });
    for (const ghost of ghosts)
      map.set(ghost.path, {
        top: ghost.top,
        height: ghost.height,
        expanded: ghost.element.getAttribute("aria-expanded"),
        copy: ghost.element,
      });
    snapshot = { time: performance.now(), height: listHeight(listElement), rows: map };
  };

  /** Reads the rows when nothing moves (one frame after a change), for the next toggle. */
  const scheduleSnapshot = () => {
    if (snapshotFrame) return;
    snapshotFrame = requestAnimationFrame(() => {
      snapshotFrame = 0;
      connect();
      const listElement = list();
      if (!listElement || folders.length) return;
      const origin = listElement.getBoundingClientRect().top;
      record(
        listElement,
        liveRows().map((element) => {
          const rect = element.getBoundingClientRect();
          return { element, path: element.dataset.itemPath ?? "", top: rect.top - origin, height: rect.height };
        }),
      );
    });
  };

  const stop = () => {
    for (const animation of animations) animation.cancel();
    animations = [];
  };

  const clearGhosts = () => {
    for (const ghost of ghosts) ghost.element.remove();
    ghosts = [];
  };

  const finish = () => {
    stop();
    clearGhosts();
    folders = [];
    layer?.remove();
    layer = null;
    scheduleSnapshot();
  };

  const ghostLayer = (listElement: HTMLElement) => {
    if (layer?.isConnected) return layer;
    layer = document.createElement("div");
    layer.dataset.cmuxTreeGhosts = "";
    layer.setAttribute("aria-hidden", "true");
    layer.style.cssText = "position:absolute;inset:0;pointer-events:none;z-index:1";
    listElement.append(layer);
    return layer;
  };

  /** Draws every running folder motion over the current layout, from `now`. */
  const plan = (motion: ArmMotion, toggled?: { path: string; open: boolean }) => {
    const listElement = list();
    if (!listElement) return;
    performance.mark("cmux-motion:tree-plan-start");
    stop();
    const now = document.timeline.currentTime as number;
    // Reads: the layout with no motion applied (the animations were just cancelled).
    const origin = listElement.getBoundingClientRect().top;
    const live = liveRows().map((element) => {
      const rect = element.getBoundingClientRect();
      return { element, path: element.dataset.itemPath ?? "", top: rect.top - origin, height: rect.height };
    });
    const scroll = scroller();
    const viewportBottom = scroll ? scroll.getBoundingClientRect().bottom - origin : Number.POSITIVE_INFINITY;
    const byPath = new Map(live.map((row) => [row.path, row]));
    if (toggled) {
      const folderRow = byPath.get(toggled.path);
      const before = snapshot;
      if (folderRow && before) {
        const previous = folders.find((folder) => folder.path === toggled.path);
        const shownBefore = folders;
        const height = Math.abs(listHeight(listElement) - before.height);
        const room = viewportBottom - (folderRow.top + folderRow.height);
        const next = startFolder(
          previous,
          {
            path: toggled.path,
            open: toggled.open,
            height,
            travel: travelFor(height, room, motion),
            top: folderRow.top,
            rowHeight: folderRow.height,
          },
          motion,
          now,
        );
        folders = [...folders.filter((folder) => folder !== previous), next];
        // Rows that left the DOM but stay on screen while the motion runs become ghosts, placed so
        // that their look now is where they were.
        const kept: Ghost[] = [];
        for (const [path, row] of before.rows) {
          if (byPath.has(path)) continue;
          const rel = relation(path, row.top, next);
          const leaves = toggled.open ? rel === "following" : rel === "descendant" || rel === "following";
          if (!leaves && !ghosts.some((ghost) => ghost.path === path)) continue;
          const existing = ghosts.find((ghost) => ghost.path === path);
          // Where it shows now (its layout place under the motions before this toggle), and its
          // layout top under the new motions: that place less its offset now.
          const shown = row.top + rowVisual({ path, top: row.top, height: row.height }, shownBefore, motion, now).y;
          const offset = rowVisual({ path, top: shown, height: row.height }, folders, motion, now).y;
          kept.push({ path, top: shown - offset, height: row.height, element: existing?.element ?? row.copy });
        }
        for (const ghost of ghosts)
          if (!kept.includes(ghost) && !kept.some((one) => one.element === ghost.element)) ghost.element.remove();
        ghosts = kept;
      }
    }
    // Folders whose motion has ended are dropped; with none left, the layout is final.
    folders = folders
      .map((folder) => ({ ...folder, top: byPath.get(folder.path)?.top ?? folder.top }))
      .filter((folder) => now < folder.start + folder.duration);
    if (!folders.length) {
      finish();
      performance.measure("cmux-motion:tree-plan", "cmux-motion:tree-plan-start");
      return;
    }
    // The next toggle starts from this plan's layout.
    record(listElement, live);
    const times = sampleTimes(folders, now);
    const duration = times[times.length - 1]! - now;
    const timing = { duration, easing: "linear", fill: "both" as const };
    const layerElement = ghosts.length ? ghostLayer(listElement) : null;
    for (const ghost of ghosts) {
      ghost.element.style.cssText += `;position:absolute;left:0;right:0;top:${ghost.top}px;height:${ghost.height}px;margin:0`;
      if (ghost.element.parentNode !== layerElement) layerElement?.append(ghost.element);
    }
    // Writes: one animation per row and per chevron, all starting at `now`.
    const targets = [
      ...live.map((row) => ({ ...row })),
      ...ghosts.map((ghost) => ({ element: ghost.element, path: ghost.path, top: ghost.top, height: ghost.height })),
    ];
    for (const target of targets) {
      const frames = rowKeyframes(target, folders, motion, times);
      if (frames.row) animations.push(target.element.animate(frames.row, timing));
      const chevron = frames.chevron && target.element.querySelector<HTMLElement>(CHEVRON);
      if (chevron && frames.chevron) animations.push(chevron.animate(frames.chevron, timing));
    }
    const token = ++generation;
    const last = animations[0];
    void last?.finished.then(
      () => token === generation && finish(),
      () => {},
    );
    if (!last) finish();
    performance.measure("cmux-motion:tree-plan", "cmux-motion:tree-plan-start");
  };

  /** Snap arms (e, and every arm under Reduce Motion): new rows crossfade in, arm e also tints. */
  const snap = (motion: ArmMotion, toggled: { path: string; open: boolean }) => {
    if (!toggled.open || !snapshot) return;
    const accent = getComputedStyle(container).getPropertyValue("--agent-accent").trim() || "#4c8dff";
    const { fade, tint } = snapKeyframes(motion, accent);
    for (const row of liveRows()) {
      const path = row.dataset.itemPath ?? "";
      if (snapshot.rows.has(path) || !path.startsWith(toggled.path.endsWith("/") ? toggled.path : `${toggled.path}/`))
        continue;
      animations.push(row.animate(fade.keyframes, { duration: fade.duration, easing: "ease-out" }));
      if (tint) animations.push(row.animate(tint.keyframes, { duration: tint.duration }));
    }
  };

  function onMutations(records: MutationRecord[]) {
    if (
      records.every(
        (record) =>
          layer?.contains(record.target) ||
          [...record.addedNodes, ...record.removedNodes].every((node) => node === layer),
      )
    )
      return;
    const motion = effectiveArm(arm, reducedMotion());
    const changed = snapshot ? toggledFolder(snapshot, liveRows()) : undefined;
    if (changed === "many") return finish();
    if (changed) {
      if (motion.kind === "snap") {
        finish();
        snap(motion, changed);
      } else plan(motion, changed);
      return;
    }
    // A scroll or a re-render while a motion runs: the same curves over the new rows.
    if (folders.length) plan(motion);
    else scheduleSnapshot();
  }

  connect();
  scheduleSnapshot();
  return () => {
    observer?.disconnect();
    finish();
    if (snapshotFrame) cancelAnimationFrame(snapshotFrame);
  };
}

/** The one folder whose aria-expanded changed since the snapshot ("many" for a bulk change). */
function toggledFolder(before: Snapshot, rows: HTMLElement[]): { path: string; open: boolean } | "many" | undefined {
  const changed: { path: string; open: boolean }[] = [];
  for (const row of rows) {
    const path = row.dataset.itemPath ?? "";
    const was = before.rows.get(path)?.expanded;
    const now = row.getAttribute("aria-expanded");
    if (was && now && was !== now) changed.push({ path, open: now === "true" });
  }
  return changed.length > 1 ? "many" : changed[0];
}

/**
 * Height of the rows of a list: Pierre writes it inline (every visible row's height). Not the
 * box's height, which `min-height: 100%` keeps at the viewport for a short list.
 */
const listHeight = (element: HTMLElement) => Number.parseFloat(element.style.height) || 0;
