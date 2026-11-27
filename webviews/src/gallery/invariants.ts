// Geometry invariants: the rules the design specs (leo-workspace design/*.md) state, read from the
// DOM of every gallery state that gallery health renders (Leo, 2026-11-01: "how about like the
// apparatuses for improving ui verification? let's examine what we can do better for our
// workflows"). Review looks at pictures and misses a row 2 px off its column; these numbers don't.
//
//   icon-column  chat-transcript.md "One icon column": "A reply's first glyph, a 'Worked for' line,
//                ... and the 16px icon box of every tool, status and message row share one left
//                edge." Each top-level transcript row's lead edge (its leading icon's 16 px box, or
//                its first text) sits on the transcript's column, the edge most rows share.
//   center-line  chat-transcript.md "glyph centered" / composer.md "every center on the prompt's
//                first line": a row's leading icon centres on the first line of text beside it.
//   gap-token    tokens.md "A new literal padding or gap must use 4/8/12/16/24/32px": the gap
//                between two transcript rows is 0, one of the transcript's gap tokens, or two of them.
//   menu-label   menus.md: "Every row of one menu starts its label on one line".
//   menu-row     menus.md: "Rows are `--ds-control-row` (28) high".
//   menu-fit     menus.md (Leo, 2026-11-01, "a picker that is too wide"): a menu is no wider than
//                its fullest row needs, its insets and columns included, unless a field-like
//                trigger sets its width ("at least as wide" as the field).
//   menu-icon-gutter  menus.md "Menus spend no width or height on nothing": in a menu whose rows carry
//                icons every action row has one; a row without one starts its text an empty icon slot
//                in (Leo, 2026-11-22: "some bullshit left indent that indents for literally nothing.
//                either get rid of the indent or give it an icon"). Toggle rows mark the slot with their check.
//   chevron-gap  docs/cmux-next/ui-guidelines.md (Leo, 2026-11-27, "these chevrons are too close dont we have any
//                guidelines for these yet?"): a chevron's ink is at least `--grid-chevron-gap` (4) from the label beside it.
//   hit-target   the same doc: a clickable icon, chevron or icon-only button is at least `--grid-hit-min` (24) square.
//   motion-max   the same doc and plans/cmux-next/motion.md: no timed transition or animation runs past the
//                scale's ceiling (`large`, 240 ms); hover, pressed and focus fills on a control run at most `micro` (120);
//                anything leaving runs at most `quick` (80), never longer than it took to arrive.
// A rule reads only what the stage shows; a state with no transcript or menu has nothing to check.
// The pure checks are here (unit tested); `collectInvariants` measures the live page.

export type Violation = { rule: string; key: string; detail: string };

/** Within this, two edges are the same line (layout rounding). */
export const EDGE_SLACK = 0.5;
/** A lead edge this far off the column is another column (an indent), not a miss. */
export const COLUMN_REACH = 8;
/** An icon centres on its line within this (glyph boxes carry a 1 px optical drop: composer.md `--acpmux-text-drop`). */
export const CENTER_SLACK = 1.01;
/** The spare width a menu's fullest row may have: two 15 px insets, three 6-12 px gaps and slack. */
export const MENU_SPARE_MAX = 112;
/** `--grid-chevron-gap`: the least ink-to-ink space between a label and its chevron (layout-grid.json). */
export const CHEVRON_GAP_MIN = 4;
/** `--grid-hit-min`: the least side of a clickable icon, chevron or icon-only button (layout-grid.json). */
export const HIT_MIN = 24;
/** The motion scale's steps (schemas/motion-scale/motion-scale.json): the ceiling, the control feedback and the exit. */
export const MOTION_MAX_MS = 240;
export const MOTION_CONTROL_MAX_MS = 120;
export const MOTION_EXIT_MAX_MS = 80;
/** The 16 px icon box of transcript rows (chat-transcript.md, `--cv-glyph-slot`). */
const GLYPH_SLOT = 16;

const half = (value: number) => Math.round(value * 2) / 2;
const fmt = (value: number) => String(Math.round(value * 10) / 10);

/** The edge most of `edges` share within `EDGE_SLACK` (ties: the leftmost), or null when no two do. */
export function sharedEdge(edges: number[]): number | null {
  let best: { edge: number; count: number } | null = null;
  for (const edge of [...edges].sort((a, b) => a - b)) {
    const count = edges.filter((other) => Math.abs(other - edge) <= EDGE_SLACK).length;
    if (count >= 2 && (!best || count > best.count)) best = { edge, count };
  }
  return best?.edge ?? null;
}

/**
 * A row's lead edge from its leading icon: a glyph up to 16 px is centred in the 16 px icon box, so
 * the box's left edge is the lead edge; a wider glyph is its own box, its left edge on the column (a
 * reply footer's 20 glyph, design/transcript-spacing.md "Reply footer": "the first glyph's box on
 * the prose's left edge", #31690).
 */
export function leadEdge(icon: { left: number; width: number }): number {
  return icon.width > GLYPH_SLOT ? icon.left : icon.left + icon.width / 2 - GLYPH_SLOT / 2;
}

/** The logical start edge of a box: its right edge in a right-to-left row, its left edge otherwise. */
export function startEdge(rect: { left: number; right: number }, rtl: boolean): number {
  return rtl ? rect.right : rect.left;
}

/** Rows whose lead edge is near the shared column but not on it. */
export function offColumn(rows: { key: string; edge: number }[], rule: string, what: string): Violation[] {
  const column = sharedEdge(rows.map(({ edge }) => edge));
  if (column === null) return [];
  return rows
    .filter(({ edge }) => Math.abs(edge - column) > EDGE_SLACK && Math.abs(edge - column) <= COLUMN_REACH)
    .map(({ key, edge }) => ({
      rule,
      key: `${rule}:${key}`,
      detail: `${key}: ${what} at x ${fmt(edge)}, the column is at ${fmt(column)} (${fmt(edge - column)} px)`,
    }));
}

/** Gaps that are neither 0 nor one or two of `tokens`. */
export function offTokenGaps(gaps: { key: string; gap: number }[], tokens: number[]): Violation[] {
  const allowed = new Set<number>([0]);
  for (const a of tokens) {
    allowed.add(half(a));
    for (const b of tokens) allowed.add(half(a + b));
  }
  return gaps
    .filter(({ gap }) => gap > EDGE_SLACK && ![...allowed].some((token) => Math.abs(token - gap) <= EDGE_SLACK))
    .map(({ key, gap }) => ({
      rule: "gap-token",
      key: `gap-token:${key}`,
      detail: `${key}: a ${fmt(gap)} px gap is no gap token (${[...new Set(tokens.map(half))].sort((a, b) => a - b).join(", ")} px, or two of them)`,
    }));
}

// ---- Measuring the live page ----

type Rect = { left: number; right: number; top: number; bottom: number; width: number; height: number };

const visible = (rect: Rect) => rect.width > 0 && rect.height > 0;

function textRects(root: Element, skip?: string): Rect[] {
  const rects: Rect[] = [];
  const walker = root.ownerDocument.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.textContent?.trim()) continue;
    const parent = node.parentElement;
    if (!parent || (skip && parent.closest(skip)) || parent.closest("[aria-hidden='true'], .sr-only")) continue;
    const range = root.ownerDocument.createRange();
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) if (visible(rect)) rects.push(rect);
  }
  return rects;
}

/** A key that survives copy edits: the row id, a data id or value attribute, the accessible name (never a generated id), and
 * only then the element's text (a copy-only PR would otherwise rename a listed violation). */
function labelOf(element: Element): string {
  const row = element.getAttribute("data-row-id");
  if (row) return `row ${row}`;
  for (const name of ["data-id", "data-value", "value", "aria-label"]) {
    const value = element.getAttribute(name);
    if (value) return `${element.tagName.toLowerCase()}[${name}=${JSON.stringify(value.slice(0, 40))}]`;
  }
  const text = (element.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 40);
  return text ? JSON.stringify(text) : element.tagName.toLowerCase();
}

/** The leading icon of a row: its first drawn svg or spinner, small and at the row's start. */
function leadingIcon(row: Element): Element | null {
  const box = row.getBoundingClientRect();
  for (const icon of row.querySelectorAll("svg, .cv-spinner")) {
    // The edited-files card's artwork centres beside its title and counts, not one text line.
    if (icon.closest(".acpmux-edited-icon")) continue;
    const rect = icon.getBoundingClientRect();
    if (!visible(rect) || rect.width > 24 || rect.height > 24 || rect.width < 6) continue;
    return rect.left - box.left <= 40 ? icon : null;
  }
  return null;
}

function pxTokens(element: Element): number[] {
  const style = getComputedStyle(element);
  const tokens: number[] = [];
  const names = new Set<string>();
  for (const sheet of element.ownerDocument.styleSheets) {
    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      continue;
    }
    for (const rule of rules)
      if (rule instanceof CSSStyleRule)
        for (const name of rule.style) if (/^--(cv|ds|acpmux)-.*(gap|space)/.test(name)) names.add(name);
  }
  for (const name of names) {
    const value = style.getPropertyValue(name).trim();
    const match = /^(-?\d+(?:\.\d+)?)px$/.exec(value);
    if (match && Number(match[1]) > 0) tokens.push(Number(match[1]));
  }
  for (const space of [4, 8, 12, 16, 24, 32]) tokens.push(space);
  return [...new Set(tokens)];
}

/** Row spacing is layout geometry. A fold's compositor translate can be held halfway by a
 * gallery play; its intermediate drawn gap need not be a token. The shift check still measures
 * that motion. Read the virtualizer's subpixel placement in their shared coordinate space. */
function transcriptGap(above: HTMLElement, below: HTMLElement): number {
  const a = getComputedStyle(above);
  const b = getComputedStyle(below);
  if (
    above.offsetParent === below.offsetParent &&
    a.position === "absolute" &&
    b.position === "absolute" &&
    a.boxSizing === "border-box"
  ) {
    const gap =
      Number.parseFloat(b.top) +
      Number.parseFloat(b.marginTop) -
      Number.parseFloat(a.top) -
      Number.parseFloat(a.marginTop) -
      Number.parseFloat(a.height);
    if (Number.isFinite(gap)) return gap;
  }
  return below.getBoundingClientRect().top - above.getBoundingClientRect().bottom;
}

function transcriptViolations(doc: Document): Violation[] {
  const violations: Violation[] = [];
  for (const scroller of doc.querySelectorAll(".acpmux-scroll")) {
    const view = scroller.getBoundingClientRect();
    const rows = [...scroller.querySelectorAll("[data-row-id]")].filter((row) => {
      if (row.parentElement?.closest("[data-row-id]")) return false;
      const rect = row.getBoundingClientRect();
      return visible(rect) && rect.bottom > view.top && rect.top < view.bottom;
    });
    const leads: { key: string; edge: number }[] = [];
    for (const row of rows) {
      const key = labelOf(row);
      const icon = leadingIcon(row);
      const text = textRects(row)[0];
      if (icon) {
        const rect = icon.getBoundingClientRect();
        leads.push({ key, edge: leadEdge(rect) });
        const line = textRects(row).find((candidate) => candidate.top < rect.bottom && candidate.bottom > rect.top);
        if (line) {
          const delta = rect.top + rect.height / 2 - (line.top + line.height / 2);
          if (Math.abs(delta) > CENTER_SLACK)
            violations.push({
              rule: "center-line",
              key: `center-line:${key}`,
              detail: `${key}: its icon centres ${fmt(delta)} px off its first line`,
            });
        }
      } else if (text) leads.push({ key, edge: text.left });
    }
    violations.push(...offColumn(leads, "icon-column", "the lead edge"));
    const gaps: { key: string; gap: number }[] = [];
    for (let index = 1; index < rows.length; index++) {
      const gap = transcriptGap(rows[index - 1]! as HTMLElement, rows[index]! as HTMLElement);
      if (gap < -EDGE_SLACK) continue;
      gaps.push({
        key: `${labelOf(rows[index - 1]!)} -> ${labelOf(rows[index]!)}`,
        gap: half(gap),
      });
    }
    violations.push(...offTokenGaps(gaps, pxTokens(scroller)));
  }
  return violations;
}

/** The action rows of a menu whose other rows carry icons but they do not (`menu-icon-gutter`). */
export function iconGutterGaps(name: string, rows: { label: string; icon: boolean; toggle: boolean }[]): Violation[] {
  const actions = rows.filter((row) => !row.toggle);
  if (!actions.some((row) => row.icon)) return [];
  return actions
    .filter((row) => !row.icon)
    .map((row) => ({
      rule: "menu-icon-gutter",
      key: `menu-icon-gutter:${name} ${row.label}`,
      detail: `${name} ${row.label}: no icon in a menu whose other rows have one, so its text starts an empty icon slot in`,
    }));
}

const MENU_ICON = ":scope > :is(.ui-menu-icon, .icon-menu-emoji)";
const TOGGLE = "[role='menuitemcheckbox'], [role='menuitemradio'], [aria-checked]";

// A listbox counts only inside a popup: a list panel the width of its pane is no menu.
const MENU = ".ui-popup, [role='menu'], [popover] [role='listbox'], [role='dialog'] [role='listbox']";
const ITEM = ".ui-menu-item, [role='menuitem'], [role='menuitemradio'], [role='menuitemcheckbox'], [role='option']";
const NOT_LABEL = ".ui-menu-check, .ui-menu-shortcut, kbd, [aria-hidden='true']";

function menuViolations(doc: Document): Violation[] {
  const violations: Violation[] = [];
  const menus = [...doc.querySelectorAll(MENU)].filter(
    (menu) => !menu.parentElement?.closest(MENU) && visible(menu.getBoundingClientRect()),
  );
  const rowHeight = Number.parseFloat(getComputedStyle(doc.documentElement).getPropertyValue("--ds-control-row")) || 28;
  for (const menu of menus) {
    // A scroll shell (`.ui-popup-scroll-shell`) carries the glass and no name of its own; the list it
    // holds does, so the menu keeps the name its rows' list gives it.
    const named = menu.matches(".ui-popup-scroll-shell:not([aria-label])")
      ? (menu.querySelector(":scope > [aria-label]") ?? menu)
      : menu;
    const name = labelOf(named).slice(0, 48);
    const items = [...menu.querySelectorAll(ITEM)].filter((item) => visible(item.getBoundingClientRect()));
    if (items.length < 2) continue;
    violations.push(
      ...offColumn(
        items.flatMap((item) => {
          const label = textRects(item, NOT_LABEL)[0];
          return label
            ? [{ key: `${name} ${labelOf(item)}`, edge: startEdge(label, getComputedStyle(item).direction === "rtl") }]
            : [];
        }),
        "menu-label",
        "the label",
      ),
    );
    violations.push(
      ...iconGutterGaps(
        name,
        items
          .filter((item) => item.classList.contains("ui-menu-item"))
          .map((item) => ({
            label: labelOf(item),
            icon: !!item.querySelector(MENU_ICON),
            toggle: item.matches(TOGGLE),
          })),
      ),
    );
    for (const item of items) {
      if (!item.classList.contains("ui-menu-item")) continue;
      const rect = item.getBoundingClientRect();
      const lines = new Set(textRects(item, NOT_LABEL).map((line) => half(line.top)));
      if (lines.size === 1 && Math.abs(rect.height - rowHeight) > EDGE_SLACK)
        violations.push({
          rule: "menu-row",
          key: `menu-row:${name} ${labelOf(item)}`,
          detail: `${name} ${labelOf(item)}: a one-line row ${fmt(rect.height)} px high, not --ds-control-row (${rowHeight})`,
        });
    }
    // The fullest row's spare width: the row less what it draws (text runs and icons).
    const menuRect = menu.getBoundingClientRect();
    const trigger = doc.querySelector("[aria-expanded='true'][data-field-trigger]");
    if (trigger && menuRect.width <= trigger.getBoundingClientRect().width + 1) continue;
    const spare = Math.min(
      ...items.map((item) => {
        const drawn = [
          ...textRects(item),
          ...[...item.querySelectorAll("svg, img")].map((icon) => icon.getBoundingClientRect()).filter(visible),
        ];
        return menuRect.width - drawn.reduce((sum, rect) => sum + rect.width, 0);
      }),
    );
    if (spare > MENU_SPARE_MAX)
      violations.push({
        rule: "menu-fit",
        key: `menu-fit:${name}`,
        detail: `${name}: ${fmt(menuRect.width)} px wide but its fullest row draws ${fmt(menuRect.width - spare)} px (${fmt(spare)} px spare, at most ${MENU_SPARE_MAX})`,
      });
  }
  return violations;
}

// ---- Chevrons, hit targets and motion ----

/** The ink gap between a chevron and a label beside it, or a hit box under the minimum. Pure, for the unit tests. */
export function tightChevronGap(gap: number, min = CHEVRON_GAP_MIN): boolean {
  return gap < min - EDGE_SLACK;
}

export function smallHitTarget(width: number, height: number, min = HIT_MIN): boolean {
  return width < min - EDGE_SLACK || height < min - EDGE_SLACK;
}

/** The longest finite duration in a computed `transition-duration` or `animation-duration` list, in ms. */
export function longestMs(list: string, skipIndexes: ReadonlySet<number> = new Set()): number {
  return Math.max(
    0,
    ...list.split(",").map((part, index) => {
      if (skipIndexes.has(index)) return 0;
      const text = part.trim();
      return text.endsWith("ms") ? parseFloat(text) : text.endsWith("s") ? parseFloat(text) * 1000 : 0;
    }),
  );
}

const CHEVRON_CLASS = /chevron|caret|disclosure-arrow/i;
const CONTROL = "button, a[href], summary, [role='button'], [role='combobox'], [role='tab'], [aria-haspopup]";
const EXIT_STATE =
  ".is-leaving, .is-exiting, .is-closing, .is-out, [data-state='closed'], [data-leaving], [data-exiting], [data-closing]";

function classOf(element: Element): string {
  const raw = element.getAttribute("class") ?? "";
  return raw.trim().split(/\s+/).filter(Boolean).slice(0, 2).join(".");
}

/** A selector-like name that survives copy edits: tag and first classes, up the controls' ancestry. */
function describe(element: Element): string {
  const one = (node: Element) => `${node.tagName.toLowerCase()}${classOf(node) ? `.${classOf(node)}` : ""}`;
  const parent = element.parentElement;
  return parent && parent !== element.ownerDocument.body ? `${one(parent)} > ${one(element)}` : one(element);
}

function isChevron(element: Element): boolean {
  if (element.closest("[aria-hidden='true'] [aria-hidden='true']")) return false;
  const icon = element.getAttribute("data-icon") ?? "";
  const named = CHEVRON_CLASS.test(element.getAttribute("class") ?? "") || /^chevron/i.test(icon);
  if (!named) return false;
  // A wrapper that holds the svg is not the chevron; the svg is.
  return element.localName === "svg" || !element.querySelector("svg");
}

/** The ink of a chevron: an svg's path boxes (their stroke's half-width added), else its own box. */
function chevronInk(element: Element): Rect | null {
  if (element.localName !== "svg") {
    const rect = element.getBoundingClientRect();
    return visible(rect) ? rect : null;
  }
  const svg = element as SVGSVGElement;
  const box = svg.getBoundingClientRect();
  if (!visible(box)) return null;
  const view = svg.viewBox?.baseVal;
  const unit = view && view.width ? box.width / view.width : 1;
  let left = Infinity;
  let right = -Infinity;
  let top = Infinity;
  let bottom = -Infinity;
  for (const shape of svg.querySelectorAll("path, polyline, line")) {
    const rect = shape.getBoundingClientRect();
    if (!visible(rect) && rect.width + rect.height === 0) continue;
    const stroke = getComputedStyle(shape).stroke;
    const pad = stroke && stroke !== "none" ? (parseFloat(getComputedStyle(shape).strokeWidth) || 0) * unit * 0.5 : 0;
    left = Math.min(left, rect.left - pad);
    right = Math.max(right, rect.right + pad);
    top = Math.min(top, rect.top - pad);
    bottom = Math.max(bottom, rect.bottom + pad);
  }
  if (!Number.isFinite(left)) return box;
  return { left, right, top, bottom, width: right - left, height: bottom - top };
}

/** `rect` less what an overflow-clipping ancestor (up to `scope`) hides: an ellipsised label draws less than its text runs. */
function clipped(rect: Rect, from: Element | null, scope: Element): Rect | null {
  let { left, right } = rect;
  for (let node = from; node && node !== scope.parentElement; node = node.parentElement) {
    const overflow = getComputedStyle(node).overflowX;
    if (overflow === "visible") continue;
    const box = node.getBoundingClientRect();
    left = Math.max(left, box.left);
    right = Math.min(right, box.right);
  }
  return right > left ? { ...rect, left, right, width: right - left } : null;
}

/** Text a chevron sits against: the control's own labels, or its parent's when the chevron stands outside it. */
function neighbours(chevron: Element): Rect[] {
  const control = chevron.closest(CONTROL);
  const scope = control ?? chevron.parentElement;
  if (!scope) return [];
  const found: Rect[] = [];
  const walker = scope.ownerDocument.createTreeWalker(scope, 4 /* NodeFilter.SHOW_TEXT */);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const parent = node.parentElement;
    if (!node.textContent?.trim() || !parent || parent.closest("[aria-hidden='true'], .sr-only")) continue;
    const range = scope.ownerDocument.createRange();
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) {
      const shown = visible(rect) ? clipped(rect, parent, scope) : null;
      if (shown) found.push(shown);
    }
  }
  return found;
}

function chevronViolations(doc: Document): Violation[] {
  const violations: Violation[] = [];
  const rtl = doc.documentElement.dir === "rtl" || getComputedStyle(doc.body).direction === "rtl";
  for (const chevron of doc.querySelectorAll("svg, [class], [data-icon]")) {
    if (!isChevron(chevron) || chevron.closest("[hidden], [inert]")) continue;
    const ink = chevronInk(chevron);
    if (!ink || getComputedStyle(chevron).visibility === "hidden") continue;
    const middle = (ink.top + ink.bottom) / 2;
    const beside = neighbours(chevron).filter((rect) => rect.top < middle && rect.bottom > middle);
    // Before the chevron (its start side) and after it; only a label close enough to read as its label counts.
    const before = beside.filter((rect) => (rtl ? rect.left >= ink.right - 1 : rect.right <= ink.left + 1));
    const after = beside.filter((rect) => (rtl ? rect.right <= ink.left + 1 : rect.left >= ink.right - 1));
    const gaps = [
      before.length ? Math.min(...before.map((rect) => (rtl ? rect.left - ink.right : ink.left - rect.right))) : null,
      after.length ? Math.min(...after.map((rect) => (rtl ? ink.left - rect.right : rect.left - ink.right))) : null,
    ].filter((gap): gap is number => gap !== null && gap <= 16);
    const gap = gaps.length ? Math.min(...gaps) : null;
    if (gap !== null && tightChevronGap(gap))
      violations.push({
        rule: "chevron-gap",
        key: `chevron-gap:${describe(chevron.closest(CONTROL) ?? chevron)}`,
        detail: `${describe(chevron)}: ${fmt(gap)} px of ink between the chevron and its label, at least ${CHEVRON_GAP_MIN} (--grid-chevron-gap)`,
      });
  }
  return violations;
}

function hitTargetViolations(doc: Document): Violation[] {
  const violations: Violation[] = [];
  for (const control of doc.querySelectorAll(CONTROL)) {
    if (control.closest("[hidden], [inert]") || (control as HTMLElement).dataset.hitExempt !== undefined) continue;
    if ((control as HTMLButtonElement).disabled) continue;
    const rect = control.getBoundingClientRect();
    if (!visible(rect) || getComputedStyle(control).visibility === "hidden") continue;
    // A control that is a mark and no label: icon-only, or a bare chevron (text rects: none).
    const marks = [...control.querySelectorAll("svg, img")].filter((mark) => visible(mark.getBoundingClientRect()));
    const labelled = textRects(control).length > 0 || control.getAttribute("href") !== null;
    if (marks.length === 0 || (labelled && !marks.some(isChevron))) continue;
    if (labelled) {
      // A labelled control with a chevron is a trigger: its height is the hit target; width follows its label.
      if (rect.height < HIT_MIN - EDGE_SLACK)
        violations.push({
          rule: "hit-target",
          key: `hit-target:${describe(control)}`,
          detail: `${describe(control)}: ${fmt(rect.width)} x ${fmt(rect.height)} px, ${HIT_MIN} px high at least (--grid-hit-min)`,
        });
      continue;
    }
    if (smallHitTarget(rect.width, rect.height))
      violations.push({
        rule: "hit-target",
        key: `hit-target:${describe(control)}`,
        detail: `${describe(control)}: ${fmt(rect.width)} x ${fmt(rect.height)} px, ${HIT_MIN} x ${HIT_MIN} at least (--grid-hit-min)`,
      });
  }
  return violations;
}

function motionViolations(doc: Document): Violation[] {
  const violations: Violation[] = [];
  const seen = new Set<string>();
  const push = (rule: string, element: Element, detail: string) => {
    const key = `${rule}:${describe(element)}`;
    if (seen.has(key)) return;
    seen.add(key);
    violations.push({ rule, key, detail: `${describe(element)}: ${detail}` });
  };
  for (const element of doc.body.querySelectorAll("*")) {
    const style = getComputedStyle(element);
    const transition = longestMs(style.transitionDuration);
    const looping = new Set(
      style.animationIterationCount.split(",").flatMap((count, index) => (count.trim() === "infinite" ? [index] : [])),
    );
    const animation = longestMs(style.animationDuration, looping);
    const longest = Math.max(transition, animation);
    if (longest > MOTION_MAX_MS)
      push("motion-max", element, `${fmt(longest)} ms, the scale ends at ${MOTION_MAX_MS} (--cmux-motion-large)`);
    else if (transition > MOTION_CONTROL_MAX_MS && element.matches(CONTROL))
      push(
        "motion-max",
        element,
        `${fmt(transition)} ms on a control, hover and press fills take at most ${MOTION_CONTROL_MAX_MS} (--cmux-motion-micro)`,
      );
    if (longest > MOTION_EXIT_MAX_MS && element.matches(EXIT_STATE))
      push("motion-exit", element, `leaves in ${fmt(longest)} ms, at most ${MOTION_EXIT_MAX_MS} (--cmux-motion-quick)`);
  }
  return violations;
}

/** Every invariant the stage breaks now, sorted by key. */
export function collectInvariants(doc: Document = document): Violation[] {
  return [
    ...transcriptViolations(doc),
    ...menuViolations(doc),
    ...chevronViolations(doc),
    ...hitTargetViolations(doc),
    ...motionViolations(doc),
  ].sort((a, b) => a.key.localeCompare(b.key));
}
