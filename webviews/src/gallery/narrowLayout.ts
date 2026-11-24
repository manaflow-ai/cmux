// Narrow-pane layout rules: what a pane at a narrow width must never draw (Leo, 2026-11-22: "ok, so
// simply prepare for this scenario beforehand and lay things out better").
//
// Two rules, read from the live DOM after a gallery stage settles:
//
// - overlap: two drawn things (text runs, icons, controls) that are not one inside the other cover
//   each other. A label running under its pane's buttons, two chips stacked on one spot and a time
//   drawn over a title are the recurring kinds.
// - ellipsis: a box that cuts its text with an ellipsis (text-overflow: ellipsis, or a line clamp)
//   is cutting it now. Some cuts are designed (a long path in a 320 px pane); the test's baseline
//   lists those, so a PR that makes one more label give way is the one that is caught.
//
// webviews/test/narrow-pane-layout-browser.test.ts opens key agent pane states at narrow widths and
// fails on a violation the baseline does not list. Pure helpers are exported for unit tests.

export type NarrowViolation = { rule: "overlap" | "ellipsis"; key: string; detail: string };

export type Box = { left: number; right: number; top: number; bottom: number };

/** Two boxes overlap when their shared area is past `slack` px in both directions and covers at least
 * a quarter of the smaller one's height: a tight line height lets adjacent lines touch by a pixel or
 * two, which no reader sees. */
export const OVERLAP_SLACK = 2;

export function intersection(a: Box, b: Box): Box | null {
  const box = {
    left: Math.max(a.left, b.left),
    right: Math.min(a.right, b.right),
    top: Math.max(a.top, b.top),
    bottom: Math.min(a.bottom, b.bottom),
  };
  return box.right > box.left && box.bottom > box.top ? box : null;
}

export function overlaps(a: Box, b: Box, slack = OVERLAP_SLACK): boolean {
  const shared = intersection(a, b);
  if (!shared) return false;
  const width = shared.right - shared.left;
  const height = shared.bottom - shared.top;
  const smaller = Math.min(a.bottom - a.top, b.bottom - b.top);
  return width > slack && height > slack && height >= smaller / 4;
}

/** Whether a box that cuts with an ellipsis is cutting now: its content is wider (or, clamped, taller) than it. */
export function truncated(
  metrics: { scrollWidth: number; clientWidth: number; scrollHeight: number; clientHeight: number },
  clamped: boolean,
): boolean {
  if (metrics.scrollWidth > metrics.clientWidth + 1) return true;
  return clamped && metrics.scrollHeight > metrics.clientHeight + 1;
}

/** A key with list positions and generated ids blanked, so a fixture that gains a row keeps its keys. */
export function narrowKeyKind(key: string): string {
  return key.replace(/-\d+(?=$|[-:\s\]"])/g, "-#").replace(/\b[0-9a-f]{8,}\b/g, "#");
}

// ---- Measuring the live page ----

const POPUP = ".ui-popup, [role='menu'], [role='dialog'], [role='tooltip'], [role='listbox'], [popover]";
const CONTROL = "button, a[href], input, select, textarea, [role='button'], [role='tab'], [role='switch']";
const SKIP = "[aria-hidden='true'], .sr-only, [data-gallery-chrome]";

type Atom = { element: Element; box: Box; kind: "text" | "icon" | "control"; layer: Element | null };

function drawn(element: Element): boolean {
  const check = (element as HTMLElement).checkVisibility;
  if (typeof check === "function")
    return check.call(element, { opacityProperty: true, visibilityProperty: true, contentVisibilityAuto: true });
  return true;
}

/** `box` cut to every clipping ancestor of `element`; null when nothing of it shows. */
function clipped(element: Element, box: Box): Box | null {
  let out: Box | null = box;
  for (let node = element.parentElement; node && out; node = node.parentElement) {
    const style = getComputedStyle(node);
    if (style.overflowX === "visible" && style.overflowY === "visible") continue;
    out = intersection(out, node.getBoundingClientRect());
  }
  const view = { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight };
  return out && intersection(out, view);
}

/** The text a key names an element by: its own label, and the nearest labelled ancestor's. */
function keyOf(element: Element): string {
  const name = (el: Element): string | null => {
    for (const attr of ["data-row-id", "data-testid", "data-id", "aria-label", "title"]) {
      const value = el.getAttribute(attr);
      if (value) return `[${attr}=${JSON.stringify(value.slice(0, 32))}]`;
    }
    return null;
  };
  const tag = element.tagName.toLowerCase();
  const cls = [...element.classList].find((c) => !/^_|[0-9a-f]{6,}/.test(c));
  const own = name(element) ?? (cls ? `.${cls}` : "");
  let anchor: string | null = null;
  for (let node = element.parentElement; node && !anchor; node = node.parentElement) anchor = name(node);
  return `${tag}${own}${anchor ? ` in ${anchor}` : ""}`;
}

function atoms(root: Element): Atom[] {
  const out: Atom[] = [];
  const add = (element: Element, rect: Box, kind: Atom["kind"]) => {
    const box = clipped(element, rect);
    if (box && box.right - box.left > 1 && box.bottom - box.top > 1)
      out.push({ element, box, kind, layer: element.closest(POPUP) });
  };
  const walker = root.ownerDocument.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const parent = node.parentElement;
    if (!node.textContent?.trim() || !parent || parent.closest(SKIP) || !drawn(parent)) continue;
    if (parent.closest("script, style, noscript")) continue;
    const range = root.ownerDocument.createRange();
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) if (rect.width > 0 && rect.height > 0) add(parent, rect, "text");
  }
  for (const element of root.querySelectorAll(`svg, img, ${CONTROL}`)) {
    if (element.closest(SKIP) || !drawn(element)) continue;
    // An icon inside a control is the control's; an svg's own parts are the svg's.
    if (element.parentElement?.closest("svg")) continue;
    const isControl = element.matches(CONTROL);
    if (!isControl && element.parentElement?.closest(CONTROL)) continue;
    const rect = element.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) continue;
    add(element, rect, isControl ? "control" : "icon");
  }
  return out;
}

/** Whether the thing at the shared area's centre is one of the pair: an opaque layer above both hides them. */
function seen(a: Atom, b: Atom, shared: Box): boolean {
  const doc = a.element.ownerDocument;
  const hit = doc.elementFromPoint((shared.left + shared.right) / 2, (shared.top + shared.bottom) / 2);
  if (!hit) return true;
  const within = (atom: Atom) => atom.element === hit || atom.element.contains(hit) || hit.contains(atom.element);
  return within(a) || within(b);
}

function overlapViolations(root: Element): NarrowViolation[] {
  const list = atoms(root).sort((x, y) => x.box.top - y.box.top);
  const found = new Map<string, NarrowViolation>();
  for (let i = 0; i < list.length; i++) {
    const a = list[i]!;
    for (let j = i + 1; j < list.length; j++) {
      const b = list[j]!;
      if (b.box.top >= a.box.bottom) break;
      if (a.element === b.element || a.element.contains(b.element) || b.element.contains(a.element)) continue;
      // A menu or dialog drawn over the pane covers it by design; inside one layer the rule holds.
      if (a.layer !== b.layer) continue;
      if (!overlaps(a.box, b.box)) continue;
      const shared = intersection(a.box, b.box)!;
      if (!seen(a, b, shared)) continue;
      const [first, second] = [keyOf(a.element), keyOf(b.element)].sort();
      const key = `overlap:${first} / ${second}`;
      if (found.has(key)) continue;
      found.set(key, {
        rule: "overlap",
        key,
        detail: `${a.kind} ${keyOf(a.element)} and ${b.kind} ${keyOf(b.element)} cover each other over ${Math.round(shared.right - shared.left)}x${Math.round(shared.bottom - shared.top)} px`,
      });
    }
  }
  return [...found.values()];
}

function ellipsisViolations(root: Element): NarrowViolation[] {
  const found = new Map<string, NarrowViolation>();
  for (const element of [root, ...root.querySelectorAll("*")]) {
    if (!(element instanceof HTMLElement) || element.closest(SKIP)) continue;
    const style = getComputedStyle(element);
    const clamp = style.getPropertyValue("-webkit-line-clamp");
    const clamped = !!clamp && clamp !== "none";
    if (style.textOverflow !== "ellipsis" && !clamped) continue;
    if (!element.textContent?.trim() || !drawn(element)) continue;
    if (!clipped(element, element.getBoundingClientRect())) continue;
    if (!truncated(element, clamped)) continue;
    const key = `ellipsis:${keyOf(element)}`;
    if (found.has(key)) continue;
    found.set(key, {
      rule: "ellipsis",
      key,
      detail: `${keyOf(element)} cuts ${JSON.stringify((element.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 60))}: ${element.scrollWidth} px of text in ${element.clientWidth} px`,
    });
  }
  return [...found.values()];
}

/** Every narrow-pane rule the page breaks now, sorted by key. */
export function collectNarrowLayout(doc: Document = document): NarrowViolation[] {
  const root = doc.querySelector("[data-gallery-capture]") ?? doc.getElementById("root") ?? doc.body;
  return [...overlapViolations(root), ...ellipsisViolations(root)].sort((a, b) => a.key.localeCompare(b.key));
}
