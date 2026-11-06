// Back returns to where the person was: before a page leaves a history entry, it notes the
// document's scroll, every nested scroller that scrolled (vertical and horizontal) and the text
// selection; when Back shows that entry again it sets them all in one frame. Nothing re-renders and
// no transcript replays: the snapshot is offsets and paths only, read from and written to the DOM
// that is there (chat paging and virtualization stay their owners').
//
// An element is named by a stable key when it has one (`data-scroll-key`, else its id) and by its
// child-index path below the nearest keyed ancestor otherwise, so a re-created element is found by
// where it is, not by object identity. An entry that no longer resolves is skipped.

export interface ScrollEntry {
  path: string;
  top: number;
  left: number;
}

export interface SelectionPoint {
  path: string;
  offset: number;
}

export interface PageSnapshot {
  scroll: ScrollEntry[];
  selection: { anchor: SelectionPoint; focus: SelectionPoint } | null;
}

/** The attribute a page puts on a scroller whose DOM position may change between renders. */
export const SCROLL_KEY_ATTRIBUTE = "data-scroll-key";

function keyOf(node: Node): string | null {
  if (node.nodeType !== 1) return null;
  const el = node as Element;
  const key = el.getAttribute(SCROLL_KEY_ATTRIBUTE);
  if (key) return `k:${key}`;
  return el.id ? `#${el.id}` : null;
}

/** `node`'s name: a key, or `<key or ^>/i/j...` child indexes below the nearest keyed ancestor. */
export function pathOf(node: Node, doc: Document): string | null {
  const steps: number[] = [];
  let current: Node = node;
  while (current !== doc.documentElement) {
    const key = keyOf(current);
    if (key) return [key, ...steps.reverse()].join("/");
    const parent: Node | null = current.parentNode;
    if (!parent) return null;
    steps.push(Array.prototype.indexOf.call(parent.childNodes, current) as number);
    current = parent;
  }
  return ["^", ...steps.reverse()].join("/");
}

export function resolvePath(path: string, doc: Document): Node | null {
  const [head, ...rest] = path.split("/");
  let node: Node | null = null;
  if (head === "^") node = doc.documentElement;
  else if (head?.startsWith("#")) node = doc.getElementById(head.slice(1));
  else if (head?.startsWith("k:")) {
    const key = head.slice(2);
    node =
      Array.from(doc.querySelectorAll(`[${SCROLL_KEY_ATTRIBUTE}]`)).find(
        (el) => el.getAttribute(SCROLL_KEY_ATTRIBUTE) === key,
      ) ?? null;
  }
  for (const step of rest) {
    if (!node) return null;
    node = node.childNodes[Number(step)] ?? null;
  }
  return node;
}

/** Notes the document's scroll, each of `scrolled` (the scrollers that moved) and the selection. */
export function snapshotPage(doc: Document, scrolled: Iterable<Element>): PageSnapshot {
  const scroll: ScrollEntry[] = [];
  const root = doc.scrollingElement ?? doc.documentElement;
  const seen = new Set<Element>();
  for (const el of [root, ...scrolled]) {
    if (seen.has(el) || !el.isConnected) continue;
    seen.add(el);
    const path = pathOf(el, doc);
    if (path) scroll.push({ path, top: el.scrollTop, left: el.scrollLeft });
  }
  let selection: PageSnapshot["selection"] = null;
  const live = doc.getSelection();
  if (live?.anchorNode && live.focusNode && !live.isCollapsed) {
    const anchor = pathOf(live.anchorNode, doc);
    const focus = pathOf(live.focusNode, doc);
    if (anchor && focus) {
      selection = {
        anchor: { path: anchor, offset: live.anchorOffset },
        focus: { path: focus, offset: live.focusOffset },
      };
    }
  }
  return { scroll, selection };
}

function clampOffset(node: Node, offset: number): number {
  const length = node.nodeType === 3 ? (node.textContent ?? "").length : node.childNodes.length;
  return Math.min(Math.max(offset, 0), length);
}

/** Puts the snapshot's offsets and selection back, all in this one call (one frame). */
export function restorePage(doc: Document, snapshot: PageSnapshot): void {
  for (const entry of snapshot.scroll) {
    const node = resolvePath(entry.path, doc);
    if (!node || node.nodeType !== 1) continue;
    const el = node as Element;
    el.scrollTop = entry.top;
    el.scrollLeft = entry.left;
  }
  if (!snapshot.selection) return;
  const anchor = resolvePath(snapshot.selection.anchor.path, doc);
  const focus = resolvePath(snapshot.selection.focus.path, doc);
  if (!anchor || !focus) return;
  doc
    .getSelection()
    ?.setBaseAndExtent(
      anchor,
      clampOffset(anchor, snapshot.selection.anchor.offset),
      focus,
      clampOffset(focus, snapshot.selection.focus.offset),
    );
}

/** One snapshot per history entry, the newest `limit` entries only (least recently used goes). */
export class SnapshotStore {
  private readonly entries = new Map<string, PageSnapshot>();

  constructor(private readonly limit = 50) {}

  get(key: string): PageSnapshot | undefined {
    const snapshot = this.entries.get(key);
    if (snapshot) {
      this.entries.delete(key);
      this.entries.set(key, snapshot);
    }
    return snapshot;
  }

  set(key: string, snapshot: PageSnapshot): void {
    this.entries.delete(key);
    this.entries.set(key, snapshot);
    while (this.entries.size > this.limit) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }
}
