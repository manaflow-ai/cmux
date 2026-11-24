// The width a row's hover-only controls cover at the end of its text (ui/motion/motion.css
// `.ui-reveal-text`): each controls element passed to `revealControls` writes its own width, as
// `--ui-reveal-controls-w`, on the nearest `.ui-reveal-host` or `[data-reveal-host]` (else its parent), and again whenever it
// changes size (a translated label, a control that comes and goes). Opacity does not take an element
// out of layout, so a hidden one still measures.

const HOST = ".ui-reveal-host, [data-reveal-host]";
const VAR = "--ui-reveal-controls-w";

const hostOf = (controls: Element) => (controls.closest(HOST) ?? controls.parentElement) as HTMLElement | null;

function write(controls: Element) {
  const host = hostOf(controls);
  if (!host) return;
  const width = `${Math.ceil(controls.getBoundingClientRect().width)}px`;
  if (host.style.getPropertyValue(VAR) !== width) host.style.setProperty(VAR, width);
}

let observer: ResizeObserver | undefined;
const observe = (el: Element) => {
  observer ??=
    typeof ResizeObserver === "undefined"
      ? undefined
      : // A stand-in observer (a test's, a polyfill's) may call back with no entries.
        new ResizeObserver((entries?: readonly ResizeObserverEntry[]) => {
          for (const entry of entries ?? []) write(entry.target);
        });
  observer?.observe(el);
};

/// A callback ref for a row's trailing controls: it measures them for the row's text's cover. Once
/// they leave (a row that turns out to be a teammate's draws none) the row's text covers nothing.
export function revealControls(el: HTMLElement | null): (() => void) | void {
  if (!el) return;
  const host = hostOf(el);
  write(el);
  observe(el);
  return () => {
    observer?.unobserve(el);
    host?.style.removeProperty(VAR);
  };
}
