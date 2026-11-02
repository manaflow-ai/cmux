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
        // The icon is centred in its 16 px box: the box's left edge is the lead edge.
        leads.push({ key, edge: rect.left + rect.width / 2 - GLYPH_SLOT / 2 });
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
      const above = rows[index - 1]!.getBoundingClientRect();
      const below = rows[index]!.getBoundingClientRect();
      if (below.top < above.bottom - EDGE_SLACK) continue;
      gaps.push({
        key: `${labelOf(rows[index - 1]!)} -> ${labelOf(rows[index]!)}`,
        gap: half(below.top - above.bottom),
      });
    }
    violations.push(...offTokenGaps(gaps, pxTokens(scroller)));
  }
  return violations;
}

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
    const name = labelOf(menu).slice(0, 48);
    const items = [...menu.querySelectorAll(ITEM)].filter((item) => visible(item.getBoundingClientRect()));
    if (items.length < 2) continue;
    violations.push(
      ...offColumn(
        items.flatMap((item) => {
          const label = textRects(item, NOT_LABEL)[0];
          return label ? [{ key: `${name} ${labelOf(item)}`, edge: label.left }] : [];
        }),
        "menu-label",
        "the label",
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

/** Every invariant the stage breaks now, sorted by key. */
export function collectInvariants(doc: Document = document): Violation[] {
  return [...transcriptViolations(doc), ...menuViolations(doc)].sort((a, b) => a.key.localeCompare(b.key));
}
