// THE PAGE'S OWN GLASS BLURS WHAT IT COVERS (Leo 2026-11-22: "ugh there's more like doubled up
// glass/wack looking glass all over the place...."; 2026-10-30: "I don't like the non-glassness").
// A cover surface (a menu, a popover, a combobox list: data-host-glass-cover) gets real glass two ways:
// the App draws its glass under the page and the page blurs itself under it (hostGlass.ts, the agent
// pane), or, in every other first-party page, nothing did: Chromium's backdrop draws its blurred copy
// over the page's pixels, so the diff viewer's Branch and options menus showed the diff's lines crisp
// through a flat tint. Here, in each page the shared desktop layer installs, a cover surface the App
// does not draw blurs what it covers in place (seeThroughBlur.ts), and glass.css drops its underlay
// (data-glass-over), so it reads as the agent pane's menus do: a tint over the page, blurred.
//
// Which surfaces: every popup glass (.ui-popup.ui-glass: Base UI's menus and popovers and a page's own,
// like the diff toolbar's) portalled into <body> (Base UI's default container, every page without a
// UiProvider container, and the diff toolbar's createPortal) that the App is not drawing (no data-host-glass-drawn="1"; hostGlass.ts
// blurs those itself) and that are not closing (data-ending-style: the blur is all or nothing, so a
// closing surface fades out on its underlay, as hostGlass.ts does). What they cover: <body>'s other
// element children (the page's root), never another popup. A popup drawn in place in the page (the
// diff's options menu) cannot be seen from <body> without watching the page: it calls
// useInPlaceGlassBlur, which blurs what it covers along its ancestors (coveredInPlace).
//
// Cost: nothing in WebKit (its backdrop takes in the page; attachSeeThroughBlur returns at once) or
// outside a see-through page (glass.css applies no filter there). Otherwise one MutationObserver on
// <body>'s direct children (never its subtree, so the page's own updates never reach it) and, while
// a surface is open, one on that surface's own attributes. The blur's own cost is seeThroughBlur's.
import type { RefObject } from "react";
import { attachSeeThroughBlur, type CoveredCandidates, useSeeThroughBlur } from "./seeThroughBlur";

const COVER = ".ui-popup.ui-glass";
const DRAWN = "data-host-glass-drawn";
const ENDING = "data-ending-style";

/** <body>'s child that holds `element` (its portal), or null. */
function portalOf(element: Element): Element | null {
  const body = element.ownerDocument.body;
  let node: Element | null = element;
  while (node && node.parentElement !== body) node = node.parentElement;
  return node;
}

/** What a body-portalled surface covers: <body>'s other element children, minus other popups. */
export const underBodyPortal: CoveredCandidates = (surface) => {
  const own = portalOf(surface);
  return [...surface.ownerDocument.body.children].filter(
    (child) =>
      child !== own && child.localName !== "svg" && child.localName !== "script" && !child.querySelector(COVER),
  );
};

/** What a popup drawn in place covers: at each level from it up to <body>, the siblings of the
 * element holding it (the page beside the menu: the file list, the diff), minus other popups. */
export const coveredInPlace: CoveredCandidates = (surface) => {
  const body = surface.ownerDocument.body;
  const covered: Element[] = [];
  for (let node: Element | null = surface; node && node !== body; node = node.parentElement) {
    const parent: Element | null = node.parentElement;
    if (!parent) break;
    for (const child of parent.children)
      if (
        child !== node &&
        child.localName !== "svg" &&
        child.localName !== "script" &&
        !child.matches(COVER) &&
        !child.querySelector(COVER)
      )
        covered.push(child);
  }
  return covered;
};

/** A popup drawn in place in the page (not portalled into <body>, where installPageGlassBlur finds
 * it) blurs what it covers while `open`. */
export function useInPlaceGlassBlur(surface: RefObject<HTMLElement | null>, open: boolean): void {
  useSeeThroughBlur(surface, open, coveredInPlace);
}

/** Whether the page blurs under `surface` now: not drawn by the App and not closing. */
export function pageBlursUnder(surface: Element): boolean {
  return surface.isConnected && surface.getAttribute(DRAWN) !== "1" && !surface.hasAttribute(ENDING);
}

type Attach = typeof attachSeeThroughBlur;

/** Blurs the page under each cover surface in `doc`'s <body> portals while it stays open and the
 * App does not draw it. Returns the stop. `attach` is the blur (a test passes its own). */
export function installPageGlassBlur(doc: Document, attach: Attach = attachSeeThroughBlur): () => void {
  const view = doc.defaultView;
  const body = doc.body;
  if (!view || !body || typeof view.MutationObserver !== "function") return () => undefined;
  const blurs = new Map<HTMLElement, () => void>();
  const surfaceWatch = new view.MutationObserver(() => sync());
  const sync = () => {
    const open = new Set<HTMLElement>();
    for (const child of body.children) {
      if (page.has(child) || child.localName === "svg") continue;
      for (const surface of child.matches(COVER) ? [child] : child.querySelectorAll(COVER))
        if (surface instanceof view.HTMLElement) open.add(surface);
    }
    for (const [surface, detach] of blurs)
      if (!open.has(surface) || !pageBlursUnder(surface)) {
        detach();
        blurs.delete(surface);
      }
    surfaceWatch.disconnect();
    for (const surface of open) {
      surfaceWatch.observe(surface, { attributes: true, attributeFilter: [DRAWN, ENDING] });
      if (!blurs.has(surface) && pageBlursUnder(surface)) blurs.set(surface, attach(surface, underBodyPortal));
    }
  };
  // A portal's content can mount a task after its wrapper, so each wrapper's subtree is watched too.
  // <body>'s children when the layer installs are the page itself (its root); only those added later
  // (Base UI's portal wrappers, which carry no marker) are watched, so the page's own updates never
  // reach an observer here.
  const page = new Set<Element>(body.children);
  const portals = new view.MutationObserver(() => sync());
  const bodyWatch = new view.MutationObserver(() => {
    portals.disconnect();
    for (const child of body.children)
      if (!page.has(child) && child.localName !== "svg") portals.observe(child, { childList: true, subtree: true });
    sync();
  });
  bodyWatch.observe(body, { childList: true });
  sync();
  return () => {
    bodyWatch.disconnect();
    portals.disconnect();
    surfaceWatch.disconnect();
    for (const detach of blurs.values()) detach();
    blurs.clear();
  };
}
