// The right edge of a transcript block whose lines run past it (an unwrapped diff, Shell block or
// output): `MORE_RIGHT` marks each sideways scroller while more of its lines lie past its right
// edge, and the block's CSS fades that edge out (conversation.css, `PIERRE_BLOCK_CSS` inside
// Pierre's shadow root). Scrolled to the end, the mark goes and the edge is hard again.
// `SIDEWAYS_ATTRIBUTE` marks it while its lines run past its width at all, and it keeps a thin
// thumb under them at rest (scrollers.ts), so a line cut at the edge reads as one that scrolls
// (Leo 2026-10-21, ask-d900f5acf9). Trackpad swipes and Shift-wheel scroll the box itself (WebKit's
// own sideways scroll; the app leaves a swipe over it to the page, PageInputReadiness `sideways`).
import { installSidewaysScrollers, SIDEWAYS_ATTRIBUTE } from "../../../scrollers";

/// On a sideways scroller while content lies past its right edge.
export const MORE_RIGHT = "data-more-right";

/// Whether `box` has content past its right edge (a half pixel of slack for zoomed pages).
const moreRight = (box: Element) => box.scrollLeft + box.clientWidth < box.scrollWidth - 0.5;
/// Whether `box`'s content is wider than it, scrolled or not.
const sideways = (box: Element) => box.clientWidth < box.scrollWidth - 0.5;

/// Keeps `MORE_RIGHT` and `SIDEWAYS_ATTRIBUTE` current on `container` and on every Pierre code
/// box inside it (its sideways scrollers, `[data-code]` in the shadow roots Pierre draws in): on
/// each scroll and size change of one, and once a frame for the boxes whose lines changed.
///
/// Only mount walks the whole block. A change (a streamed token, a new line, Pierre drawing) marks
/// the box it is in, takes in only the nodes it added and lets go of those it removed, a removed
/// host's shadow root and all: no work per change grows with the block's lines, and nothing it
/// watched outlives its place in the block (Codex review of #23967). Its frame, its observers and
/// its listeners end with the returned stop function.
export function watchSideways(container: HTMLElement): () => void {
  // The page's desktop layer installs it at start (installScrollers); a page without one gets it here.
  installSidewaysScrollers(container.ownerDocument);
  const view = container.ownerDocument.defaultView;
  /// Each watched box: its update, and what of it the size observer watches.
  const watched = new Map<Element, { update: () => void; sized: Element[] }>();
  /// Boxes whose lines changed since the last frame.
  const dirty = new Set<Element>();
  /// Custom elements without their shadow root yet: Pierre attaches it as it draws.
  const hosts = new Set<Element>();
  /// The change observer of `container` and of each shadow root in it, so one leaves with its host.
  const observers = new Map<Node, MutationObserver>();
  let frame: number | undefined;
  const resize = view?.ResizeObserver
    ? new view.ResizeObserver((entries) =>
        entries.forEach(({ target }) => {
          watched.get(target)?.update();
          if (hosts.has(target)) adopt(target);
        }),
      )
    : undefined;
  const observe = (root: Node) => {
    if (!view?.MutationObserver || observers.has(root)) return;
    const observer = new view.MutationObserver((records) => changed(records));
    observer.observe(root, { childList: true, subtree: true, characterData: true });
    observers.set(root, observer);
  };
  const watch = (box: Element) => {
    if (watched.has(box)) return;
    const update = () => {
      box.toggleAttribute(MORE_RIGHT, moreRight(box));
      box.toggleAttribute(SIDEWAYS_ATTRIBUTE, sideways(box));
    };
    const sized = [box, ...box.children];
    watched.set(box, { update, sized });
    box.addEventListener("scroll", update, { passive: true });
    for (const element of sized) resize?.observe(element);
    update();
  };
  /// Stops watching `element`, and everything in its shadow root if it hosts one.
  function forget(element: Element) {
    const box = watched.get(element);
    if (box) {
      element.removeEventListener("scroll", box.update);
      for (const sized of box.sized) resize?.unobserve(sized);
      watched.delete(element);
      dirty.delete(element);
    }
    if (hosts.delete(element)) resize?.unobserve(element);
    const shadow = element.shadowRoot;
    const observer = shadow && observers.get(shadow);
    if (!observer) return;
    observer.disconnect();
    observers.delete(shadow);
    for (const inner of shadow.querySelectorAll("*")) forget(inner);
  }
  /// A shadow host: its root's code boxes, and the root's own changes. One without a root yet
  /// waits in `hosts` until it resizes or the next frame.
  function adopt(host: Element) {
    const shadow = host.shadowRoot;
    if (!shadow) {
      if (!hosts.has(host)) {
        hosts.add(host);
        resize?.observe(host);
      }
      return;
    }
    if (hosts.delete(host)) resize?.unobserve(host);
    if (observers.has(shadow)) return;
    observe(shadow);
    take(shadow);
  }
  const visit = (element: Element) => {
    if (element.hasAttribute("data-code")) watch(element);
    if (element.shadowRoot || element.localName.includes("-")) adopt(element);
  };
  /// `node` and what lies under it: an added node, a shadow root, or the block at mount.
  function take(node: Node) {
    if (node.nodeType === 1) visit(node as Element);
    else if (node.nodeType !== 11) return;
    for (const element of (node as ParentNode).querySelectorAll("*")) visit(element);
  }
  /// A removed node and what lies under it, shadow roots too.
  function drop(node: Node) {
    if (node.nodeType !== 1) return;
    forget(node as Element);
    for (const element of (node as Element).querySelectorAll("*")) forget(element);
  }
  function changed(records: MutationRecord[]) {
    for (const record of records) {
      const at = record.target.nodeType === 1 ? (record.target as Element) : record.target.parentElement;
      const box = at?.closest("[data-code]");
      dirty.add(box && watched.has(box) ? box : container);
      for (const node of record.addedNodes) take(node);
      for (const node of record.removedNodes) drop(node);
    }
    frame ??= view?.requestAnimationFrame(flush);
  }
  function flush() {
    frame = undefined;
    for (const host of hosts) adopt(host);
    for (const box of dirty) watched.get(box)?.update();
    dirty.clear();
  }
  watch(container);
  observe(container);
  take(container);
  return () => {
    if (frame !== undefined) view?.cancelAnimationFrame(frame);
    for (const observer of observers.values()) observer.disconnect();
    observers.clear();
    resize?.disconnect();
    for (const [box, { update }] of watched) box.removeEventListener("scroll", update);
    watched.clear();
    dirty.clear();
    hosts.clear();
  };
}

/// Added to the `unsafeCSS` of Pierre's diff and code in a transcript block: a wrapped line hangs
/// under its first row (the continuation starts two characters further in), an unwrapped row
/// that runs past the right edge fades out there while it does, and a block cut to its preview
/// (`--cv-block-cut`, conversation.css) cuts the code box too, so the box's sideways scrollbar
/// sits at the cut's bottom, in view, rather than under the last line past it.
export const PIERRE_BLOCK_CSS = /* css */ `
[data-overflow="wrap"] [data-line] { padding-inline-start: 4ch; text-indent: -2ch; }
[data-code][${MORE_RIGHT}] { mask-image: linear-gradient(to left, transparent, #000 32px); }
[data-code] { max-height: var(--cv-block-cut, none); }
`;
