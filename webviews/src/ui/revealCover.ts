// The width a row's hover-only controls cover at the end of its text (ui/motion/motion.css
// `.ui-reveal-text`): each controls element passed to `revealControls` writes its own width, as
// `--ui-reveal-controls-w`, on the nearest `.ui-reveal-host` or `[data-reveal-host]` (else its parent), and again whenever it
// changes size (a translated label, a control that comes and goes). Opacity does not take an element
// out of layout, so a hidden one still measures.
//
// A host marked `data-reveal-overlap` has words that do not always run to the controls (a line whose
// chevron follows its words, the controls before its time): there the cover is only the part of the
// controls that lies over the words (0 when the words end before them), and the host carries
// `data-reveal-crowded` while a `.ui-reveal-under` mark (that chevron) lies under the controls, so
// the mark gives way too. Its words fade at their end only where something is cut: at rest while
// they overflow (`data-reveal-cut`), on hover while the controls lie over them (`data-reveal-covers`);
// a short line keeps its last letters whole. Those depend on where the words end, so the words and
// the host are measured as well.

// The reveal's rules (.ui-reveal, .ui-reveal-text) come with the ref, so every row that uses it has them.
import "./motion/motion.css";

const HOST = ".ui-reveal-host, [data-reveal-host]";
const VAR = "--ui-reveal-controls-w";
const CROWDED = "data-reveal-crowded";
const COVERS = "data-reveal-covers";
const CUT = "data-reveal-cut";

const mark = (host: HTMLElement, name: string, on: boolean) => {
  if (on !== host.hasAttribute(name)) host.toggleAttribute(name, on);
};

const hostOf = (controls: Element) => (controls.closest(HOST) ?? controls.parentElement) as HTMLElement | null;

/// How far the controls lie over `under`, along the line (from its end side): 0 when apart.
function overlap(controls: DOMRect, under: DOMRect, rtl: boolean): number {
  if (under.width === 0) return 0;
  const over = rtl ? Math.min(under.right, controls.right) - under.left : under.right - controls.left;
  return Math.max(0, Math.min(controls.width, over));
}

function write(controls: Element) {
  const host = hostOf(controls);
  if (!host) return;
  const box = controls.getBoundingClientRect();
  let cover = box.width;
  if (host.hasAttribute("data-reveal-overlap")) {
    // The host's own window: a test's DOM (or another frame) has no global getComputedStyle.
    const view = host.ownerDocument.defaultView;
    const rtl = view ? view.getComputedStyle(host).direction === "rtl" : host.closest("[dir=rtl]") !== null;
    const text = host.querySelector(".ui-reveal-text");
    cover = text ? overlap(box, text.getBoundingClientRect(), rtl) : 0;
    const crowded = [...host.querySelectorAll(".ui-reveal-under")].some(
      (under) => overlap(box, under.getBoundingClientRect(), rtl) > 0,
    );
    mark(host, CROWDED, crowded);
    mark(host, COVERS, cover > 0);
    mark(host, CUT, text !== null && text.scrollWidth > text.clientWidth + 1);
  }
  const width = `${Math.ceil(cover)}px`;
  if (host.style.getPropertyValue(VAR) !== width) host.style.setProperty(VAR, width);
}

// The controls of each measured host: a resize of the host or its words measures them again.
const controlsOf = new WeakMap<Element, Element>();
let observer: ResizeObserver | undefined;
const observe = (el: Element) => {
  observer ??=
    typeof ResizeObserver === "undefined"
      ? undefined
      : // A stand-in observer (a test's, a polyfill's) may call back with no entries.
        new ResizeObserver((entries?: readonly ResizeObserverEntry[]) => {
          for (const entry of entries ?? []) write(controlsOf.get(entry.target) ?? entry.target);
        });
  observer?.observe(el);
};

/// A callback ref for a row's trailing controls: it measures them for the row's text's cover. Once
/// they leave (a row that turns out to be a teammate's draws none) the row's text covers nothing.
export function revealControls(el: HTMLElement | null): (() => void) | void {
  if (!el) return;
  write(el);
  observe(el);
  const host = hostOf(el);
  const text = host?.hasAttribute("data-reveal-overlap") ? host.querySelector(".ui-reveal-text") : null;
  const watched = host && text ? [host, text] : [];
  for (const target of watched) {
    controlsOf.set(target, el);
    observe(target);
  }
  return () => {
    observer?.unobserve(el);
    for (const target of watched) {
      controlsOf.delete(target);
      observer?.unobserve(target);
    }
    if (!host) return;
    host.style.removeProperty(VAR);
    for (const name of [CROWDED, COVERS, CUT]) mark(host, name, false);
  };
}
