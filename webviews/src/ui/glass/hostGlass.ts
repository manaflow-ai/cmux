// HOST GLASS: the App draws a floating surface's glass under the page, as its native menus are drawn
// (Leo, 2026-11-06: "why the f*** is this not glass? Like the way the native menus are. We can just do
// that, right? Like we're literally in Swift"). In a see-through Chromium page a CSS backdrop-filter
// never reaches the window glass behind the page, so a floating `.ui-glass` lays the theme surface under
// its tint (glass.css, "CHROMIUM OVER THE WINDOW GLASS") and reads as a flat box. A surface marked
// `data-host-glass="<level>"` instead tells the App its box (`pane.glass {surfaces}`); the App puts its own
// glass surface there, under the page (CmuxNextAgentPane AgentPaneView+HostGlass.swift: the same
// material, tint and Reduce Transparency fallback as its popovers), and the page draws the surface's
// content on no fill of its own. Only the presentation crosses: the content, its layout, focus, keys and
// dismissal stay in the page.
//
// No flash and no pop: a marked surface draws nothing until the App has answered the report that
// carried it (`data-host-glass-drawn="1"`), so it never shows as a clear box first. That is one round trip
// after its first frame; past HOST_GLASS_DEADLINE_MS it shows with the page's own glass
// (`data-host-glass-drawn="0"`, today's look), so a slow or older App never hides a menu.
//
// Cost: one MutationObserver (added nodes and the marker attribute only), and while a marked surface
// moves (an open, a fade, a resize, a scroll), one rect and opacity read per surface per frame. The loop
// stops after STABLE_FRAMES unchanged frames; a resize, a style write, a transition or a scroll starts it
// again. Nothing runs while no marked surface is mounted, and the App's answer is the only other work.
import { LENS_ATTRIBUTE, LIVE_BACKGROUND_ATTRIBUTE } from "./glassState";
import { attachSeeThroughBlur, type CoveredCandidates, type SeeThroughOptions } from "./seeThroughBlur";

/** pages/shared/desktop.ts SEE_THROUGH_ATTRIBUTE: the page sits on the window glass. */
const SEE_THROUGH_ATTRIBUTE = "data-cmux-see-through";

/** On a surface: the level the App draws its glass at (design/glass.md "Glass levels"). */
export const HOST_GLASS_ATTRIBUTE = "data-host-glass";
/** On a surface: "1" once the App draws its glass, "0" when the page draws its own (past the deadline,
 * or an App that cannot). */
export const HOST_GLASS_DRAWN_ATTRIBUTE = "data-host-glass-drawn";
/** On a surface: the page under it blurs in place once the App draws its glass (the reporter's `cover`).
 * A surface that blurs what it covers itself (Session Info, a hover card given `under`) leaves it off. */
export const HOST_GLASS_COVER_ATTRIBUTE = "data-host-glass-cover";
/** On `<html>` while the App draws host glass: glass.css hides a marked surface until it is drawn. */
export const HOST_GLASS_ROOT_ATTRIBUTE = "data-host-glass-on";

export type HostGlassLevel = "popover" | "menu" | "chip";
const LEVELS: ReadonlySet<string> = new Set<HostGlassLevel>(["popover", "menu", "chip"]);

/** One surface's box in the page's viewport (CSS px), its corner radius and its own opacity (a fade). */
export type HostGlassSurface = {
  id: string;
  level: HostGlassLevel;
  left: number;
  top: number;
  right: number;
  bottom: number;
  radius: number;
  opacity: number;
};

/** The most surfaces one report carries (the App refuses more). */
export const HOST_GLASS_MAX = 16;
/** How long a new surface waits for the App before it draws the page's own glass. */
export const HOST_GLASS_DEADLINE_MS = 50;
/** Unchanged frames before the follow loop stops. */
const STABLE_FRAMES = 3;

const SELECTOR = `[${HOST_GLASS_ATTRIBUTE}]`;
const round = (value: number) => Math.round(value * 100) / 100;

/** Whether the App's glass can show under this page now: a see-through Chromium page (WebKit's own
 * backdrop already takes in the window glass), outside the lens and the live background (whose
 * canvases cover what is under the page) and Reduce Transparency (every glass is opaque there). */
export function hostGlassApplies(doc: Document): boolean {
  const root = doc.documentElement;
  if (!root.hasAttribute(SEE_THROUGH_ATTRIBUTE) || root.hasAttribute(LENS_ATTRIBUTE)) return false;
  if (root.hasAttribute(LIVE_BACKGROUND_ATTRIBUTE)) return false;
  if (root.hasAttribute("data-reduce-transparency")) return false;
  const css = doc.defaultView?.CSS;
  return !(css?.supports?.("-webkit-backdrop-filter", "none") ?? true);
}

/** A marked surface's report, or none: unmounted, hidden, drawn by the App past the window's edge
 * (`data-escaped`), empty or without a known level. Its own `opacity` is read, so a fade follows. */
export function hostGlassSurface(element: Element, id: string): HostGlassSurface | undefined {
  const level = element.getAttribute(HOST_GLASS_ATTRIBUTE) ?? "";
  if (!LEVELS.has(level) || !element.isConnected || element.closest("[hidden],[data-escaped]")) return undefined;
  const style = element.ownerDocument.defaultView?.getComputedStyle(element);
  if (style && (style.display === "none" || style.visibility === "hidden")) return undefined;
  const box = element.getBoundingClientRect();
  if (!(box.width > 0 && box.height > 0)) return undefined;
  const radius = Number.parseFloat(style?.borderTopLeftRadius ?? "") || 0;
  const opacity = Number.parseFloat(style?.opacity ?? "1");
  return {
    id,
    level: level as HostGlassLevel,
    left: round(box.left),
    top: round(box.top),
    right: round(box.right),
    bottom: round(box.bottom),
    radius: round(Math.min(radius, box.width / 2, box.height / 2)),
    opacity: Number.isFinite(opacity) ? round(Math.min(1, Math.max(0, opacity))) : 1,
  };
}

/**
 * Keeps the App told where the page's marked surfaces are (`post`, whose promise settles once the App
 * drew that report), and marks each surface drawn when it has. A refused report means the App draws no
 * host glass: every surface keeps the page's own glass and the reports end. Returns the stop, which
 * sends an empty list if the last report was not.
 */
/** What a `data-host-glass-cover` surface blurs in place under it once drawn (module constants). */
export type HostGlassCover = { candidates: CoveredCandidates; options?: SeeThroughOptions };

export function reportHostGlass(
  doc: Document,
  post: (surfaces: HostGlassSurface[]) => Promise<unknown>,
  cover?: HostGlassCover,
): () => void {
  const view = doc.defaultView;
  if (!view) return () => undefined;
  const root = doc.documentElement;
  const ids = new Map<Element, string>();
  const deadlines = new Map<Element, ReturnType<typeof setTimeout>>();
  // The in-place blur of each drawn cover surface: the page's own pixels under it would read crisp
  // through its clear fill (Chromium's backdrop draws a blurred copy over them, not in their place).
  const blurs = new Map<Element, () => void>();
  const unblur = (element: Element) => {
    blurs.get(element)?.();
    blurs.delete(element);
  };
  const resize = view.ResizeObserver ? new view.ResizeObserver(() => kick()) : undefined;
  // A surface placed by its own or its positioner's inline style (Base UI rewrites it on scroll) moves
  // with no resize: that style measures again. Only the marked surfaces and their parents are watched.
  const restyled = new view.MutationObserver(() => kick());
  const watchStyles = () => {
    restyled.disconnect();
    for (const element of ids.keys()) {
      restyled.observe(element, { attributes: true, attributeFilter: ["style"] });
      if (element.parentElement)
        restyled.observe(element.parentElement, { attributes: true, attributeFilter: ["style"] });
    }
  };
  let nextId = 0;
  let frame = 0;
  let stable = 0;
  let sent = "[]";
  let live = true;

  const mark = (element: Element, drawn: "0" | "1") => {
    const timer = deadlines.get(element);
    if (timer !== undefined) clearTimeout(timer);
    deadlines.delete(element);
    if (element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE) !== drawn)
      element.setAttribute(HOST_GLASS_DRAWN_ATTRIBUTE, drawn);
    if (drawn === "0") unblur(element);
    else if (
      cover &&
      !blurs.has(element) &&
      element.hasAttribute(HOST_GLASS_COVER_ATTRIBUTE) &&
      element instanceof view!.HTMLElement
    )
      blurs.set(element, attachSeeThroughBlur(element, cover.candidates, cover.options));
  };
  // Surfaces the App did not draw by the deadline: they keep the page's glass while they stay mounted. A
  // surface that fell back only because host glass did not apply (the lens, Reduce Transparency, an
  // opaque page) goes back to the App's glass when it applies again.
  const timedOut = new WeakSet<Element>();
  const forget = (element: Element) => {
    timedOut.delete(element);
    const timer = deadlines.get(element);
    if (timer !== undefined) clearTimeout(timer);
    deadlines.delete(element);
    unblur(element);
    ids.delete(element);
    resize?.unobserve(element);
    element.removeAttribute(HOST_GLASS_DRAWN_ATTRIBUTE);
    watchStyles();
  };
  const end = () => {
    // The App cannot draw it: the page's own glass, now and for every later surface.
    live = false;
    root.removeAttribute(HOST_GLASS_ROOT_ATTRIBUTE);
    for (const element of ids.keys()) mark(element, "0");
  };
  const send = (surfaces: HostGlassSurface[], elements: Element[]) => {
    const text = JSON.stringify(surfaces);
    if (text === sent) return;
    sent = text;
    post(surfaces).then(() => {
      // An answer that comes after host glass stopped applying (Reduce Transparency, a live
      // background) draws nothing. An answer to an earlier report still draws: a surface whose box
      // changes every frame (a scroll, a fade) is never answered for its latest report in time.
      if (!live || !hostGlassApplies(doc)) return;
      // A surface that already fell back keeps the page's glass: a late answer never swaps it.
      for (const element of elements)
        if (ids.has(element) && element.isConnected && !fellBack(element)) mark(element, "1");
    }, end);
  };
  const fellBack = (element: Element) => timedOut.has(element);
  const measure = (): string => {
    const applies = live && hostGlassApplies(doc);
    root.toggleAttribute(HOST_GLASS_ROOT_ATTRIBUTE, applies);
    const surfaces: HostGlassSurface[] = [];
    const elements: Element[] = [];
    for (const [element, id] of ids) {
      if (!element.isConnected || !element.hasAttribute(HOST_GLASS_ATTRIBUTE)) {
        forget(element);
        continue;
      }
      // A fallen-back surface is not reported: the App draws no glass under the page's own.
      const surface =
        applies && surfaces.length < HOST_GLASS_MAX && !fellBack(element) ? hostGlassSurface(element, id) : undefined;
      if (surface) {
        surfaces.push(surface);
        elements.push(element);
      } else if (!applies && live) mark(element, "0");
    }
    if (live) send(surfaces, elements);
    return sent;
  };
  let last = "";
  const tick = () => {
    frame = 0;
    const key = measure();
    stable = key === last ? stable + 1 : 0;
    last = key;
    if (ids.size > 0 && stable < STABLE_FRAMES) frame = view.requestAnimationFrame(tick);
  };
  function kick() {
    stable = 0;
    if (!frame) frame = view!.requestAnimationFrame(tick);
  }
  const adopt = (element: Element) => {
    if (ids.has(element)) return;
    ids.set(element, `g${++nextId}`);
    resize?.observe(element);
    watchStyles();
    if (!live) {
      mark(element, "0");
      return;
    }
    // A slow App never hides a surface: past the deadline it draws the page's own glass.
    deadlines.set(
      element,
      setTimeout(() => {
        deadlines.delete(element);
        if (element.getAttribute(HOST_GLASS_DRAWN_ATTRIBUTE) === "1") return;
        // While host glass does not apply the surface already shows the page's glass (measure), and
        // it goes back to the App's glass when host glass applies again: only a slow App keeps it off.
        if (!hostGlassApplies(doc)) return;
        timedOut.add(element);
        mark(element, "0");
        // Measuring may have settled already (a 120 Hz display): withdraw its box from the App.
        kick();
      }, HOST_GLASS_DEADLINE_MS),
    );
  };
  const collect = (node: Node) => {
    if (node.nodeType !== 1) return;
    const element = node as Element;
    if (element.matches(SELECTOR)) adopt(element);
    // A portal mounts its positioner with the surface inside.
    if (element.firstElementChild) for (const inner of element.querySelectorAll(SELECTOR)) adopt(inner);
  };
  const observer = new view.MutationObserver((records) => {
    let changed = false;
    for (const record of records) {
      if (record.type === "attributes") {
        // The page's look changed (see-through, the lens, the live background, Reduce Transparency), or a surface was
        // marked or unmarked in place.
        const element = record.target as Element;
        if (element !== root && element.hasAttribute(HOST_GLASS_ATTRIBUTE)) adopt(element);
        changed = true;
        continue;
      }
      for (const node of record.addedNodes) collect(node);
      if (record.addedNodes.length > 0 || (record.removedNodes.length > 0 && ids.size > 0)) changed = true;
    }
    if (changed) kick();
  });
  observer.observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: [
      HOST_GLASS_ATTRIBUTE,
      SEE_THROUGH_ATTRIBUTE,
      LENS_ATTRIBUTE,
      LIVE_BACKGROUND_ATTRIBUTE,
      "data-reduce-transparency",
    ],
  });
  // A popup is placed by its positioner's inline style, rewritten on scroll; a fade is a transition.
  const follow = () => {
    if (ids.size > 0) kick();
  };
  view.addEventListener("scroll", follow, { capture: true, passive: true });
  view.addEventListener("resize", follow);
  doc.addEventListener("transitionrun", follow, true);
  doc.addEventListener("transitionend", follow, true);
  doc.addEventListener("animationstart", follow, true);
  for (const element of doc.querySelectorAll(SELECTOR)) adopt(element);
  measure();
  if (ids.size > 0) kick();
  return () => {
    observer.disconnect();
    resize?.disconnect();
    restyled.disconnect();
    view.removeEventListener("scroll", follow, { capture: true });
    view.removeEventListener("resize", follow);
    doc.removeEventListener("transitionrun", follow, true);
    doc.removeEventListener("transitionend", follow, true);
    doc.removeEventListener("animationstart", follow, true);
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    for (const element of ids.keys()) forget(element);
    restyled.disconnect();
    root.removeAttribute(HOST_GLASS_ROOT_ATTRIBUTE);
    if (live && sent !== "[]") void post([]).catch(() => undefined);
    live = false;
  };
}
