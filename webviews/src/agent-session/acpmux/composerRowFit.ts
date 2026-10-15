import { type RefObject, useLayoutEffect } from "react";

// The composer's controls row never cuts a label (Leo 2026-10-14: "Claude Opus …", "Medi…"). The
// compact-composer verdict (cg-design-judge, 2026-10-14, items 3 to 5): effort rides in the model
// chip as a dim suffix ("Opus 5.5 Fast Med", one chevron), and a narrower pane swaps whole units,
// never letters. +, the access glyph, Send or Stop and every chevron always stay.
//
// The steps are pane widths, in COMPOSER_FIT_STEPS. composerLocation.css applies them with
// container queries on the pane (`acpmux-pane`, the chat column), whose widths are literals that
// test/composer-fit-steps.test.ts holds to this table. This hook is the safety net for labels too
// long for their step (a long model name, a long mode in another language): it measures the row
// and, while its controls would not fit, applies the next steps too, writing each unit's form on
// the row (`data-fit-model="family"`).
//
// A part of a unit carries the unit's name (`data-fit-part="model"`) and the forms it shows in
// (`data-fit-forms="full family"`). A part of another form is laid out of the row, absolute and
// invisible, so its width is still known: the decision never toggles to measure. It runs when the
// row is resized and when a control in it changes, never on a keystroke in the prompt.

/** The pane widths (px, at or under) where the composer's rows give up a unit. Shared with the
 *  location strip above the row (its owner reads the machine and folder steps). */
export const COMPOSER_FIT_STEPS = {
  /** The location strip's machine shows its laptop icon alone. */
  machineIconOnly: 460,
  /** The permission mode's label goes; its glyph and chevron stay. */
  accessLabelHidden: 460,
  /** The model chip's suffix drops "Fast" and keeps the effort. */
  fastHidden: 400,
  /** The location strip's folder name truncates in the middle. */
  folderMiddleTruncate: 340,
  /** The mic leaves the row. */
  micHidden: 340,
  /** The model shows its family ("Opus"). */
  modelFamily: 340,
  /** The model shows its harness mark alone, the full value in its tooltip. */
  modelMark: 300,
  /** The effort suffix leaves the chip (it stays in the chip's tooltip and menu). */
  effortSuffixHidden: 300,
  /** The row tightens its gap and padding and narrows +. */
  barTight: 220,
} as const;

export type FitUnit = "access" | "fast" | "mic" | "model" | "effort";
export type FitForm = "full" | "family" | "icon" | "hidden";

/** The row's steps: at its width (COMPOSER_FIT_STEPS) `unit` takes the form `to`. A row too
 *  long for its width's steps takes the next ones too, in this order: the mic goes last, so a
 *  transient control (Steer while a turn runs) never moves it. One table: the steps change here. */
export const ROW_FIT_STEPS: readonly { step: keyof typeof COMPOSER_FIT_STEPS; unit: FitUnit; to: FitForm }[] = [
  { step: "accessLabelHidden", unit: "access", to: "icon" },
  { step: "fastHidden", unit: "fast", to: "hidden" },
  { step: "modelFamily", unit: "model", to: "family" },
  { step: "modelMark", unit: "model", to: "icon" },
  { step: "effortSuffixHidden", unit: "effort", to: "hidden" },
  { step: "micHidden", unit: "mic", to: "hidden" },
];

const UNITS: readonly FitUnit[] = ["access", "fast", "mic", "model", "effort"];
type Forms = Record<FitUnit, FitForm>;

/** Each unit's form in a pane `width` px wide that also took the first `extra` steps. */
export function fitForms(width: number, extra = 0, steps = ROW_FIT_STEPS): Forms {
  const forms: Forms = { access: "full", fast: "full", mic: "full", model: "full", effort: "full" };
  steps.forEach(({ step, unit, to }, index) => {
    if (index < extra || width <= COMPOSER_FIT_STEPS[step]) forms[unit] = to;
  });
  return forms;
}

/** Room a lower step needs, past what it takes, before the row goes back to it. */
const LABELS_BACK = 4;

function px(value: string): number {
  return parseFloat(value) || 0;
}

function shows(part: Element, forms: Forms): boolean {
  const unit = part.getAttribute("data-fit-part") as FitUnit | null;
  if (!unit || !UNITS.includes(unit)) return true;
  return (part.getAttribute("data-fit-forms") ?? "").split(/\s+/).includes(forms[unit]);
}

/** Whether `part` is in the row now (the CSS lays a part of another form out of it). */
function inRow(part: Element): boolean {
  const style = getComputedStyle(part);
  return style.position !== "absolute" && style.visibility !== "hidden" && style.display !== "none";
}

/** The flex items of `container`, looking through `display: contents` wrappers. */
function items(container: Element): HTMLElement[] {
  return [...container.children].flatMap((child) => {
    if (!(child instanceof HTMLElement)) return [];
    const style = getComputedStyle(child);
    if (style.display === "contents") return items(child);
    return style.display === "none" || style.position === "absolute" ? [] : [child];
  });
}

/** The width `element` takes at `then`, from the width it takes now. */
function widthAt(element: HTMLElement, then: Forms): number {
  if (element.classList.contains("acpmux-chips")) return row(element, then);
  let width = element.getBoundingClientRect().width;
  for (const part of element.querySelectorAll("[data-fit-part]")) {
    const before = inRow(part);
    if (before === shows(part, then)) continue;
    const parent = part.parentElement;
    const taken = part.getBoundingClientRect().width + (parent ? px(getComputedStyle(parent).columnGap) : 0);
    width += before ? -taken : taken;
  }
  return width;
}

/** The width a flex row's items take at `then`, gaps included. */
function row(container: HTMLElement, then: Forms): number {
  const children = items(container);
  const gap = px(getComputedStyle(container).columnGap);
  return children.reduce((sum, child) => sum + widthAt(child, then), 0) + gap * Math.max(0, children.length - 1);
}

/**
 * The extra steps the row takes: the fewest whose controls fit `room`.
 * `wanted(step)` is the width the row takes at that step. Going back to a lower step than `now`
 * needs clear room, so a row resized across a boundary by a fraction of a pixel never flips.
 */
export function fitStep(
  now: number,
  wanted: (step: number) => number,
  room: number,
  last = ROW_FIT_STEPS.length,
): number {
  for (let step = 0; step < last; step++) {
    const need = wanted(step);
    if (step < now ? need <= room - LABELS_BACK : need <= room + 0.5) return step;
  }
  return last;
}

/** The pane the row's steps follow: the chat column (the CSS's `acpmux-pane` container). */
function paneWidth(bar: HTMLElement): number {
  return (bar.closest(".acpmux-main") ?? bar.ownerDocument.documentElement).clientWidth;
}

/** The extra steps `bar` takes now (`data-fit-extra`). */
function stepOf(bar: HTMLElement): number {
  const step = Number(bar.dataset.fitExtra ?? 0);
  return Number.isInteger(step) && step >= 0 ? step : 0;
}

/** The extra steps `bar`'s controls need past its width's to fit. */
export function rowStep(bar: HTMLElement): number {
  const style = getComputedStyle(bar);
  const room = bar.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
  const width = paneWidth(bar);
  return fitStep(stepOf(bar), (step) => row(bar, fitForms(width, step)), room);
}

function show(bar: HTMLElement, step: number): void {
  if (step === 0) delete bar.dataset.fitExtra;
  else bar.dataset.fitExtra = String(step);
  const forms = fitForms(paneWidth(bar), step);
  for (const unit of UNITS) {
    const name = `data-fit-${unit}`;
    const form = forms[unit];
    if (form === "full") {
      if (bar.hasAttribute(name)) bar.removeAttribute(name);
    } else if (bar.getAttribute(name) !== form) bar.setAttribute(name, form);
  }
}

export function useRowFit(bar: RefObject<HTMLElement | null>): void {
  useLayoutEffect(() => {
    const element = bar.current;
    if (!element) return;
    // The forms follow the pane's width too, so they are written on every pass.
    const fit = () => show(element, rowStep(element));
    fit();
    // The row's own width (the pane), and a chip's (a new model or mode name, a chip that comes or goes).
    const resize = new ResizeObserver(fit);
    resize.observe(element);
    const watchChips = () => {
      for (const chip of element.querySelectorAll(".acpmux-chips, .acpmux-composer-actions")) resize.observe(chip);
    };
    watchChips();
    const mutation = new MutationObserver(() => {
      watchChips();
      fit();
    });
    mutation.observe(element, { childList: true, subtree: true, characterData: true });
    return () => {
      resize.disconnect();
      mutation.disconnect();
    };
  }, [bar]);
}
