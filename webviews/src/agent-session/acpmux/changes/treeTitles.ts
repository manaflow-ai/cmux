// Long names in the changes tree: clipped at the right edge with a fade (no ellipsis, no middle
// truncation that keeps the extension), the +N -M counts always whole, and on hover or keyboard
// focus the name scrolls once to show its end (the tabs' and workspaces' marquee: ui/titleFade.ts).
// Pierre renders the rows; diffTheme.ts lays its name out as one unclipped line inside the content
// section, and this layer measures which names are clipped (one read pass, then one write pass,
// after each change of rows) and runs the marquee on the hovered or focused one.
import { MOTION_SPRINGS, springCurve } from "../../../files-panel-motion";
import { marqueeKeyframes, marqueeTiming, titleFade } from "../../../ui/titleFade";

const ROWS = '[data-type="item"]';
const CONTENT = '[data-item-section="content"]';
/** Padding before the first glyph that the marquee fades glyphs across (diffTheme.ts `--cmux-title-lead`). */
export const TITLE_LEAD_PX = 4;
/** The marquee is ambient: it never holds a gallery step (gallery/frame/experimentRunner.ts). */
const MARQUEE_ID = "cmux-ambient:marquee";

const reducedMotion = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;

/** Fades and scrolls the clipped names of the tree inside `container`. Returns the cleanup. */
export function attachTreeTitles(container: HTMLElement, options: { fadeWidth: number }): () => void {
  const host = container.querySelector<HTMLElement>("*");
  const shadow = host?.shadowRoot;
  if (!host || !shadow) return () => {};
  host.style.setProperty("--cmux-title-fade", `${options.fadeWidth}px`);
  host.style.setProperty("--cmux-title-lead", `${TITLE_LEAD_PX}px`);
  let frame = 0;
  let active: { row: HTMLElement; path: string; text: HTMLElement; animation: Animation } | null = null;
  let hovered: HTMLElement | null = null;
  let focused: HTMLElement | null = null;

  const measure = () => {
    frame = 0;
    const reduce = reducedMotion();
    // Reads.
    const rows = [...shadow.querySelectorAll<HTMLElement>(ROWS)].flatMap((row) => {
      const content = row.querySelector<HTMLElement>(CONTENT);
      const text = content?.firstElementChild as HTMLElement | null | undefined;
      if (!content || !text) return [];
      const span = content.clientWidth - TITLE_LEAD_PX;
      const fade = titleFade({
        // The name's box, or what overflows the section (a flattened folder's segments).
        textWidth: Math.max(text.getBoundingClientRect().width, content.scrollWidth - TITLE_LEAD_PX),
        span,
        visibleWidth: span,
        trailingPadding: 0,
        fadeWidth: options.fadeWidth,
      });
      return [{ row, content, fade }];
    });
    // Writes.
    for (const { row, content, fade } of rows) {
      if (fade.truncated) {
        content.dataset.cmuxClipped = "";
        content.dataset.cmuxTravel = String(fade.marqueeTravel);
      } else {
        delete content.dataset.cmuxClipped;
        delete content.dataset.cmuxTravel;
      }
      // Reduce Motion: no marquee, so the whole name is in the tooltip.
      const label = row.getAttribute("aria-label") ?? "";
      if (reduce && fade.truncated) row.title = label;
      else if (row.title === label) row.removeAttribute("title");
    }
  };
  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(measure);
  };

  const stop = (animated: boolean) => {
    if (!active) return;
    const { text, animation } = active;
    active = null;
    // Where the name is on screen now: a name caught mid-scroll springs back from there.
    const shown = animated ? Number.parseFloat(getComputedStyle(text).translate) || 0 : 0;
    animation.cancel();
    if (Math.abs(shown) <= 0.5 || reducedMotion()) return;
    const { durationMs, progress } = springCurve(MOTION_SPRINGS.disappear);
    const keyframes = progress.map((value, index) => ({
      offset: index / (progress.length - 1),
      translate: `${Math.round(shown * (1 - value) * 100) / 100}px 0`,
    }));
    text.animate(keyframes, { duration: durationMs, easing: "linear", id: MARQUEE_ID });
  };

  const start = (row: HTMLElement) => {
    const path = row.dataset.itemPath ?? "";
    if (active?.row === row && active.path === path) return;
    stop(true);
    const content = row.querySelector<HTMLElement>(CONTENT);
    const text = content?.firstElementChild as HTMLElement | null | undefined;
    if (!content || !text || content.dataset.cmuxClipped === undefined) return;
    const travel = Number(content.dataset.cmuxTravel);
    const timing = marqueeTiming(travel, reducedMotion());
    if (!timing) return;
    const { keyframes, duration } = marqueeKeyframes(travel, timing);
    active = {
      row,
      path,
      text,
      animation: text.animate(keyframes, { duration, delay: timing.delayMs, id: MARQUEE_ID }),
    };
  };

  const target = () => hovered ?? focused;
  const update = () => {
    const row = target();
    if (row) start(row);
    else stop(true);
  };
  const rowOf = (event: Event) =>
    event.composedPath().find((node): node is HTMLElement => node instanceof HTMLElement && node.matches(ROWS)) ?? null;
  const onOver = (event: Event) => {
    hovered = rowOf(event);
    update();
  };
  const onLeave = () => {
    hovered = null;
    update();
  };
  const onFocusIn = (event: Event) => {
    focused = rowOf(event);
    update();
  };
  const onFocusOut = () => {
    focused = null;
    update();
  };

  // A reused row shows another name: measure again. A row reused under the active marquee stops it.
  const mutations = new MutationObserver(() => {
    if (active && (!active.row.isConnected || active.row.dataset.itemPath !== active.path)) stop(false);
    schedule();
  });
  mutations.observe(shadow, {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
    attributeFilter: ["data-item-path"],
  });
  const resize = new ResizeObserver(schedule);
  resize.observe(host);
  shadow.addEventListener("pointerover", onOver);
  host.addEventListener("pointerleave", onLeave);
  shadow.addEventListener("focusin", onFocusIn);
  shadow.addEventListener("focusout", onFocusOut);
  schedule();
  return () => {
    mutations.disconnect();
    resize.disconnect();
    shadow.removeEventListener("pointerover", onOver);
    host.removeEventListener("pointerleave", onLeave);
    shadow.removeEventListener("focusin", onFocusIn);
    shadow.removeEventListener("focusout", onFocusOut);
    if (frame) cancelAnimationFrame(frame);
    stop(false);
  };
}
