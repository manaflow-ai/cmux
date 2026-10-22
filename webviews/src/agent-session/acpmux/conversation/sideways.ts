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

/// Pierre's sideways scrollers in `root`'s subtree, through the shadow roots it draws in.
function pierreScrollers(root: ParentNode, into: Element[]) {
  for (const element of root.querySelectorAll("*")) {
    const shadow = element.shadowRoot;
    if (!shadow) continue;
    into.push(...shadow.querySelectorAll("[data-code]"));
    pierreScrollers(shadow, into);
  }
  return into;
}

/// Keeps `MORE_RIGHT` and `SIDEWAYS_ATTRIBUTE` current on `container` and on every Pierre code
/// box inside it: now, on each scroll, when one changes size and when Pierre draws (it renders
/// after its highlighter answers). Returns the stop function.
export function watchSideways(container: HTMLElement): () => void {
  // The page's desktop layer installs it at start (installScrollers); a page without one gets it here.
  installSidewaysScrollers(container.ownerDocument);
  const view = container.ownerDocument.defaultView;
  const watched = new Map<Element, () => void>();
  const resize = view?.ResizeObserver
    ? new view.ResizeObserver((entries) => entries.forEach(({ target }) => watched.get(target)?.()))
    : undefined;
  const shadows = new Set<ShadowRoot>();
  const mutations = view?.MutationObserver ? new view.MutationObserver(() => scan()) : undefined;
  const watch = (box: Element) => {
    if (watched.has(box)) return watched.get(box)!();
    const update = () => {
      box.toggleAttribute(MORE_RIGHT, moreRight(box));
      box.toggleAttribute(SIDEWAYS_ATTRIBUTE, sideways(box));
    };
    watched.set(box, update);
    box.addEventListener("scroll", update, { passive: true });
    resize?.observe(box);
    for (const child of box.children) resize?.observe(child);
    update();
  };
  function scan() {
    for (const box of [container, ...pierreScrollers(container, [])]) watch(box);
    for (const element of container.querySelectorAll("*"))
      if (element.shadowRoot && !shadows.has(element.shadowRoot)) {
        shadows.add(element.shadowRoot);
        mutations?.observe(element.shadowRoot, { childList: true, subtree: true });
      }
  }
  mutations?.observe(container, { childList: true, subtree: true, characterData: true });
  scan();
  return () => {
    mutations?.disconnect();
    resize?.disconnect();
    for (const [box, update] of watched) box.removeEventListener("scroll", update);
    watched.clear();
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
