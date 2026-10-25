import { type RefObject, useLayoutEffect } from "react";

// The composer's controls row never cuts a label (Leo 2026-10-14: "Claude Opus …", "Medi…"). A
// narrower pane swaps whole units, never letters: the model, effort (its own chip, Leo 2026-10-15:
// "move it back out"; since Leo 2026-10-20 the model button's detail) and the permission mode each
// take a shorter form, and +, the access glyph, the mic, Send or Stop and every chevron always stay.
// Claude Code's Fast mode is a row of the model button's menu; Codex's bolt beside the mic never
// leaves (it is Codex's only speed control), as the mic never does.
//
// The steps are composer widths, in COMPOSER_FIT_STEPS. composerLocation.css applies them with
// container queries on the composer (`composer`, #20548), whose widths are literals that
// test/composer-fit-steps.test.ts holds to this table. This hook is the safety net for labels too
// long for their step (a long model name, a long mode in another language): it measures the row
// and, while its controls would not fit, applies the next steps too, writing each unit's form on
// the row (`data-fit-model="family"`).
//
// The quiet row under the box (ComposerFoot, #22285) takes no width step: the steps date from
// #20802's one row, where +, the prompt, the chips, the mic and Send shared the width, and #22285
// moved the mode, the model button and the ring into a row of their own. There the forms follow
// what this hook measures alone: the units' natural widths against the row's room, so a 410 px
// composer keeps "Opus 5.5  Medium" while it fits (live-qa 2026-10-21 read "Opus Med" with about
// 250 px of the row free) and shortens only when the row really runs out.
//
// A part of a unit carries the unit's name (`data-fit-part="model"`) and the forms it shows in
// (`data-fit-forms="full family"`). A part of another form is laid out of the row, absolute and
// invisible, so its width is still known: the decision never toggles to measure. It runs when the
// row is resized and when a control in it changes, never on a keystroke in the prompt.

/** The composer widths (px, at or under; about the pane less 36) where the composer's rows give up a unit. Shared with the
 *  location strip above the row (its owner reads the machine and folder steps). To retune the
 *  collapse, change a width here; composerLocation.css's container queries use the same numbers
 *  (test/composer-fit-steps.test.ts holds the two together). */
export const COMPOSER_FIT_STEPS = {
  /** The location strip tightens its gap and caps its controls' width. */
  locationTight: 480,
  /** The model button's effort shows the level's short name ("Med"). */
  effortShort: 470,
  /** The location strip's machine shows its laptop icon alone. */
  machineIconOnly: 460,
  /** The model shows its family ("Opus"). */
  modelFamily: 440,
  /** The permission mode's label goes; its glyph and chevron stay. */
  accessLabelHidden: 420,
  /** The model shows its harness mark alone, its name in its tooltip. */
  modelMark: 370,
  /** The location strip's folder name truncates in the middle. */
  folderMiddleTruncate: 340,
  /** The row's group gap narrows and the card reaches 10px from the pane's edges (#20548). */
  rowTight: 297,
  /** The New Tab card's model shows its harness mark alone, its name in its tooltip. Its row holds
   *  the whole name down to about here (it has no + or Plan); narrower, the name only
   *  shrank to a sliver and pushed the permission mode into the mic. */
  newTabModelMark: 297,
  /** The row tightens its gap and padding and narrows +. */
  barTight: 260,
} as const;

export type FitUnit = "access" | "effort" | "mic" | "model";
export type FitForm = "full" | "short" | "family" | "icon" | "hidden";

/** The row's steps: at its width (COMPOSER_FIT_STEPS) `unit` takes the form `to`. Labels shorten
 *  early and whole, a little before the row runs out of room: effort's short name, the model's
 *  family, the permission label (its glyph stays), and the model's mark alone (its name only while
 *  the row can hold it, #20548). The mic never leaves (Leo 2026-10-19, as Claude Code's): the prompt gives way instead. A row too long
 *  for its width's steps takes the next ones too, in this order.
 *  One table: the steps change here. */
export const ROW_FIT_STEPS: readonly { step: keyof typeof COMPOSER_FIT_STEPS; unit: FitUnit; to: FitForm }[] = [
  { step: "effortShort", unit: "effort", to: "short" },
  { step: "modelFamily", unit: "model", to: "family" },
  { step: "accessLabelHidden", unit: "access", to: "icon" },
  { step: "modelMark", unit: "model", to: "icon" },
];

const UNITS: readonly FitUnit[] = ["access", "effort", "mic", "model"];
type Forms = Record<FitUnit, FitForm>;

/** Each unit's form in a pane `width` px wide that also took the first `extra` steps. */
export function fitForms(width: number, extra = 0, steps = ROW_FIT_STEPS): Forms {
  const forms: Forms = { access: "full", effort: "full", mic: "full", model: "full" };
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
  // A mic that is listening stays in the row (composerLocation.css): it is the way to stop.
  if (unit === "mic" && part.querySelector('[aria-pressed="true"]')) return true;
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

/** The width the row's steps follow: the composer's content box (the CSS's `composer` container,
 *  #20548), so a split pane, the New Tab card and the quick surface step down alike. */
function paneWidth(bar: HTMLElement): number {
  // The quiet row fits on its measured room alone (above): no composer width takes a step there.
  if (bar.classList.contains("acpmux-composer-foot")) return Number.POSITIVE_INFINITY;
  const composer = bar.closest<HTMLElement>(".acpmux-composer, .nt-composer");
  if (!composer) return bar.ownerDocument.documentElement.clientWidth;
  const style = getComputedStyle(composer);
  return composer.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
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
  nameIcons(bar, forms);
  for (const unit of UNITS) {
    const name = `data-fit-${unit}`;
    const form = forms[unit];
    if (form === "full") {
      if (bar.hasAttribute(name)) bar.removeAttribute(name);
    } else if (bar.getAttribute(name) !== form) bar.setAttribute(name, form);
  }
}

/** A control whose label the row folds to its glyph names itself in a tooltip then, and only then
 *  (a tooltip names a control that shows no text): its wrapper's `data-fit-title`, on its button,
 *  while its unit (`data-fit-title-unit`) is in its icon form. */
function nameIcons(bar: HTMLElement, forms: Forms): void {
  for (const wrapper of bar.querySelectorAll<HTMLElement>("[data-fit-title]")) {
    const button = wrapper.querySelector<HTMLElement>(".acpmux-picker-button");
    const name = wrapper.dataset.fitTitle ?? "";
    if (!button) continue;
    const iconOnly = forms[wrapper.dataset.fitTitleUnit as FitUnit] === "icon";
    // `data-fit-titled` holds the tooltip this wrote; a title the page set itself is left alone.
    const ours = button.dataset.fitTitled;
    if (iconOnly && name && (ours !== undefined || !button.title)) {
      if (button.title !== name) button.title = name;
      button.dataset.fitTitled = name;
    } else if (ours !== undefined) {
      if (button.title === ours) button.removeAttribute("title");
      delete button.dataset.fitTitled;
    }
  }
}

/// `row` names which element `bar` points at (the box's row or the quiet row under it): a change
/// re-attaches the fit to the element the ref holds now, so a footer look toggled live still fits.
export function useRowFit(bar: RefObject<HTMLElement | null>, row?: unknown): void {
  useLayoutEffect(() => {
    const element = bar.current;
    if (!element) return;
    // The forms follow the composer's width too, so they are written on every pass.
    const fit = () => show(element, rowStep(element));
    fit();
    // The row's own width (the pane), and a chip's (a new model or mode name, a chip that comes or goes).
    // The row's own items too, through `display: contents` wrappers (the quiet row's `.acpmux-chips`,
    // whose box a ResizeObserver never reports): a label that sets wider without the row resizing (a
    // font that loads late, Linux's wider metrics) runs the fit again, so the row never keeps a form
    // it no longer has room for (narrow-layouts `new-tab-wide-type`). The fit's own form changes
    // resize them as well; the next pass computes the same step (fitStep's LABELS_BACK keeps it from
    // flipping), so it settles. An item that leaves the row stops being observed; `disconnect` below
    // ends the rest.
    const resize = new ResizeObserver(fit);
    resize.observe(element);
    const watched = new Set<Element>();
    const watchChips = () => {
      const now = new Set<Element>([
        ...element.querySelectorAll(".acpmux-chips, .acpmux-composer-actions"),
        ...items(element),
      ]);
      for (const old of watched)
        if (!now.has(old)) {
          resize.unobserve(old);
          watched.delete(old);
        }
      for (const item of now)
        if (!watched.has(item)) {
          resize.observe(item);
          watched.add(item);
        }
    };
    watchChips();
    const mutation = new MutationObserver(() => {
      watchChips();
      fit();
    });
    // A label drawn from `data-label` (a short name, the effort suffix) changes no text node.
    mutation.observe(element, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["data-label", "data-fit-forms", "data-fit-title", "aria-pressed"],
    });
    return () => {
      resize.disconnect();
      mutation.disconnect();
    };
  }, [bar, row]);
}
