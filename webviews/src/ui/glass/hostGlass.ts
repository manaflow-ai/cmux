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
// Content and glass move together (Leo, 2026-11-09: "it loads the placeholder, THEN the content...
// every single time"). A marked surface draws its content in the first frame that paints it
// (`data-host-glass-drawn="1"`, set in the task it mounts in), and the App puts its glass there as the
// report reaches it, which never waits on the page. Waiting for the App's answer instead showed the
// App's empty glass for as long as the page stayed busy after a popup mounted (260 to 530 ms in Leo's
// recording): the answer queues behind that work. A surface that goes is withdrawn in the task it goes
// in, so its glass leaves with its content. The answer only confirms: a surface the App has not
// answered for by HOST_GLASS_DEADLINE_MS shows with the page's own glass (`data-host-glass-drawn="0"`,
// the old look), so a slow or older App never leaves a menu on no glass.
//
// Content first, then its glass (Leo, 2026-11-09, on the empty glass box before the This Mac, Cloud and
// permission menus). The App's glass is in the App's layer tree and shows at its next commit, but the
// page's frame reaches the screen through Chromium's remote layer one or two frames after the frame
// that drew it, so a report sent in the frame that first paints a surface put the App's glass on
// screen before the surface's content: an empty glass box for a frame or two on every open. A new
// surface is reported once its content has been on screen for HOST_GLASS_HOLD_FRAMES frames (on the
// page's in-place blur, `cover`), so its glass lands under content already there, and its deadline
// starts with that first report. A surface that moves or fades after it was reported is not held.
//
// A surface that starts to close (Base UI's `data-ending-style`, the 80 ms fade of popupSurface.css)
// leaves the App's glass and its in-place blur in the task its close starts in, and fades out on the
// page's own glass (Leo, 2026-11-09, of the This Mac/Cloud/Remote and Bypass permissions menus: "What
// the heck is this?"; the empty glass box stayed where the menu was after it closed). The App's glass
// is drawn in another process from the page's reports, so it can never fade in step with the content:
// it trailed the fade by the App's own latency (a pick keeps the App busy as the menu closes), and the
// blur under a cover surface is all or nothing (seeThroughBlur.ts), so it stayed whole while the rows
// faded. The page's glass is drawn with the content in one layer, so both fade in the same frames,
// and the App has the whole fade to take its glass away behind them.
//
// Cost: one MutationObserver (added nodes and the marker attribute only), and while a marked surface
// moves (an open, a fade, a resize, a scroll), one rect and opacity read per surface per frame. The loop
// stops after STABLE_FRAMES unchanged frames; a resize, a style write, a transition or a scroll starts it
// again, and so does a trackpad pinch (the visual viewport's resize and scroll), since each box is sent
// where it shows on the zoomed screen (ui/visualViewportBox.ts). Nothing runs while no marked surface is
// mounted, and the App's answer is the only other work.
import { LENS_ATTRIBUTE, LIVE_BACKGROUND_ATTRIBUTE } from "./glassState";
import { onVisualViewport, visualViewportScale } from "../visualViewportBox";
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
/** On a surface while it closes (Base UI sets it for the close fade): it leaves the App's glass. */
export const HOST_GLASS_ENDING_ATTRIBUTE = "data-ending-style";

export type HostGlassLevel = "popover" | "menu" | "chip";
const LEVELS: ReadonlySet<string> = new Set<HostGlassLevel>(["popover", "menu", "chip"]);

/** One surface's box in the page's viewport (CSS px, where it shows under a pinch zoom), its corner
 * radius and its own opacity (a fade). */
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
/** How long a reported surface waits for the App before it draws the page's own glass. */
export const HOST_GLASS_DEADLINE_MS = 50;
/** Frames a new surface's content shows before its box goes to the App: Chromium's frames reach the
 * screen this many frames after the App's own commits. */
export const HOST_GLASS_HOLD_FRAMES = 2;
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
  const layout = element.getBoundingClientRect();
  if (!(layout.width > 0 && layout.height > 0)) return undefined;
  // Where it shows under a trackpad pinch, so the App's glass zooms and pans with its content.
  const view = element.ownerDocument.defaultView;
  const box = onVisualViewport(layout, view);
  const scale = visualViewportScale(view);
  const radius = (Number.parseFloat(style?.borderTopLeftRadius ?? "") || 0) * scale;
  const opacity = Number.parseFloat(style?.opacity ?? "1");
  return {
    id,
    level: level as HostGlassLevel,
    left: round(box.left),
    top: round(box.top),
    right: round(box.right),
    bottom: round(box.bottom),
    radius: round(Math.min(radius, (box.right - box.left) / 2, (box.bottom - box.top) / 2)),
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
  // Frames measured so far, and the one each shown surface was first measured in (the hold).
  let paints = 0;
  const firstShown = new Map<Element, number>();
  // Surfaces reported to the App at least once: their deadline is armed.
  const reported = new WeakSet<Element>();
  let stable = 0;
  let sent = "[]";
  let live = true;

  // The deadline stays armed while a surface is marked "1" before the App answered (adopt): only an
  // answer or a fallback settles it.
  const mark = (element: Element, drawn: "0" | "1") => {
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
  // Surfaces the App answered a report for: drawn, so the deadline leaves them be.
  const answered = new WeakSet<Element>();
  // Surfaces closing (data-ending-style): never reported, on the page's glass until they go.
  const leaving = new WeakSet<Element>();
  const forget = (element: Element) => {
    timedOut.delete(element);
    answered.delete(element);
    reported.delete(element);
    firstShown.delete(element);
    leaving.delete(element);
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
        if (ids.has(element) && element.isConnected && !fellBack(element) && !leaving.has(element)) {
          answered.add(element);
          mark(element, "1");
        }
    }, end);
  };
  const fellBack = (element: Element) => timedOut.has(element);
  /** Whether the surface is closing now; one that opens again before it went is reported again. */
  const closing = (element: Element) => {
    const ending = element.hasAttribute(HOST_GLASS_ENDING_ATTRIBUTE);
    if (ending) {
      // Its glass is withdrawn: an earlier answer no longer says the App draws it if it opens again.
      leaving.add(element);
      answered.delete(element);
    } else if (
      leaving.delete(element) &&
      live &&
      reported.has(element) &&
      !answered.has(element) &&
      !timedOut.has(element)
    ) {
      // Opened again before the App answered: a deadline that passed while it closed skipped it, so
      // it gets a new one (a slow App still never leaves it on no glass). One never reported yet gets
      // its deadline with its first report, after the hold.
      const timer = deadlines.get(element);
      if (timer !== undefined) clearTimeout(timer);
      arm(element, view.performance.now(), false);
    }
    return ending;
  };
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
      // A closing surface fades out on the page's glass, and is not reported: its App glass is gone.
      if (closing(element)) {
        // Not held either: one that opens again holds again, content first.
        firstShown.delete(element);
        if (live) mark(element, "0");
        continue;
      }
      // A fallen-back surface is not reported: the App draws no glass under the page's own.
      const surface = applies && !fellBack(element) ? hostGlassSurface(element, id) : undefined;
      if (surface && surfaces.length >= HOST_GLASS_MAX) {
        // Past what one report carries: the page's own glass, at once, never content on no glass.
        firstShown.delete(element);
        mark(element, "0");
      } else if (surface) {
        // Its content shows from its first frame (marked at adopt); the App hears of it once that
        // content has been on screen for the hold, and its deadline starts then.
        mark(element, "1");
        if (!firstShown.has(element)) firstShown.set(element, paints);
        if (!reported.has(element) && paints - firstShown.get(element)! < HOST_GLASS_HOLD_FRAMES) continue;
        surfaces.push(surface);
        elements.push(element);
        if (!reported.has(element)) {
          reported.add(element);
          arm(element, view.performance.now(), false);
        }
      } else {
        // Hidden again: it holds again when it next shows.
        firstShown.delete(element);
        if (!applies && live) mark(element, "0");
      }
    }
    if (live) send(surfaces, elements);
    return sent;
  };
  let last = "";
  const holding = () => [...ids.keys()].some((element) => firstShown.has(element) && !reported.has(element));
  const tick = () => {
    frame = 0;
    paints += 1;
    const key = measure();
    stable = key === last ? stable + 1 : 0;
    last = key;
    if (ids.size > 0 && (stable < STABLE_FRAMES || holding())) frame = view.requestAnimationFrame(tick);
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
    // A surface already closing when first seen fades out on the page's glass.
    if (closing(element)) {
      mark(element, "0");
      return;
    }
    // Its content shows in the frame that first paints it, on the page's in-place blur; its report
    // goes out after the hold (measure). While host glass does not apply, measure gives it the page's.
    if (hostGlassApplies(doc)) mark(element, "1");
  };
  const arm = (element: Element, start: number, late: boolean) => {
    deadlines.set(
      element,
      setTimeout(() => {
        deadlines.delete(element);
        if (!live || answered.has(element) || !ids.has(element) || leaving.has(element)) return;
        // While host glass does not apply the surface already shows the page's glass (measure), and
        // it goes back to the App's glass when host glass applies again: only a slow App keeps it off.
        if (!hostGlassApplies(doc)) return;
        // A deadline that ran late waited behind the page's own work, where the App's answer may wait
        // too: it gets one more deadline to land.
        if (!late && view.performance.now() - start > HOST_GLASS_DEADLINE_MS * 2) {
          arm(element, start, true);
          return;
        }
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
    let gone = false;
    let ending = false;
    for (const record of records) {
      if (record.type === "attributes") {
        // The page's look changed (see-through, the lens, the live background, Reduce Transparency), or a surface was
        // marked or unmarked in place, or started or stopped closing.
        const element = record.target as Element;
        // Another popup's close (a dialog, a tooltip) is none of this reporter's.
        if (record.attributeName === HOST_GLASS_ENDING_ATTRIBUTE && !element.hasAttribute(HOST_GLASS_ATTRIBUTE))
          continue;
        if (element !== root && element.hasAttribute(HOST_GLASS_ATTRIBUTE)) {
          adopt(element);
          if (record.attributeName === HOST_GLASS_ENDING_ATTRIBUTE && element.hasAttribute(HOST_GLASS_ENDING_ATTRIBUTE))
            ending = true;
        }
        changed = true;
        continue;
      }
      for (const node of record.addedNodes) collect(node);
      if (record.addedNodes.length > 0 || (record.removedNodes.length > 0 && ids.size > 0)) changed = true;
      if (record.removedNodes.length > 0 && ids.size > 0) gone = true;
    }
    // A surface that went is withdrawn now, not on the next frame: the App takes its glass away as the
    // page paints the frame without its content.
    if (gone && [...ids.keys()].some((element) => !element.isConnected)) measure();
    // A surface that starts to close leaves the App's glass and its blur now, as its fade starts.
    else if (ending) measure();
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
      HOST_GLASS_ENDING_ATTRIBUTE,
    ],
  });
  // A popup is placed by its positioner's inline style, rewritten on scroll; a fade is a transition.
  const follow = () => {
    if (ids.size > 0) kick();
  };
  view.addEventListener("scroll", follow, { capture: true, passive: true });
  view.addEventListener("resize", follow);
  // A trackpad pinch zooms and pans the visual viewport with no layout change: the boxes move on screen.
  view.visualViewport?.addEventListener("resize", follow);
  view.visualViewport?.addEventListener("scroll", follow);
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
    view.visualViewport?.removeEventListener("resize", follow);
    view.visualViewport?.removeEventListener("scroll", follow);
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
