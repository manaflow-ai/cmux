// Writes what the chat's page shows now as a snapshot (shared.ts): `<main id="root">` as drawn, with
// the transcript rows out of view left out, so its size is the visible window's and not the
// transcript's. Reads first (every rect and scroll offset), then edits only the detached copy, so
// it forces at most the one layout the page already needs for its next frame.
import {
  attributesOf,
  PAGE_STYLE_ID,
  SNAPSHOT_MAX_CHARS,
  SNAPSHOT_SCROLL_ATTRIBUTE,
  SNAPSHOT_SHEETS_ATTRIBUTE,
  SNAPSHOT_VERSION,
  type ChatSnapshot,
} from "./shared";
import { usedNames, usedRules, type UsedNames } from "./usedRules";

/// The transcript's rows: absolutely placed, so leaving one out moves no other.
const ROW_SELECTOR = ".acpmux-row";
/// What a copy never carries: script, frames, and the page's own media (a copy cannot play it).
const DROPPED = "script, iframe, object, embed, frame, frameset, video, audio, canvas";

type Plan = { drop: boolean; scroll?: string; checked?: boolean; shadow?: ShadowRoot };

function planFor(element: Element, viewHeight: number): Plan | undefined {
  let plan: Plan | undefined;
  if (element.matches(ROW_SELECTOR)) {
    const rect = element.getBoundingClientRect();
    if (rect.bottom < 0 || rect.top > viewHeight) return { drop: true };
  }
  if (element.scrollTop > 0 || element.scrollLeft > 0)
    plan = { drop: false, scroll: `${Math.round(element.scrollTop)},${Math.round(element.scrollLeft)}` };
  // By tag, not `instanceof`: the page's realm is not always this module's (a test's window).
  const tag = element.tagName;
  // No field's text is written (``scrubFields``); a box's checked state is not text.
  if (tag === "INPUT" && (element as HTMLInputElement).checked) {
    plan ??= { drop: false };
    plan.checked = true;
  }
  const shadow = element.shadowRoot;
  if (shadow) {
    plan ??= { drop: false };
    plan.shadow = shadow;
  }
  return plan;
}

function sheetText(sheet: CSSStyleSheet): string {
  try {
    return Array.from(sheet.cssRules, (rule) => rule.cssText).join("\n");
  } catch {
    return "";
  }
}

/// The open shadow root's markup as a declarative shadow root (its adopted sheets go by index, below).
function shadowTemplate(doc: Document, shadow: ShadowRoot): HTMLTemplateElement {
  const template = doc.createElement("template");
  template.setAttribute("shadowrootmode", "open");
  template.innerHTML = shadow.innerHTML;
  for (const node of Array.from(template.content.querySelectorAll(DROPPED))) node.remove();
  return template;
}

/// Input types whose `value` is a label or a choice the page wrote, not something typed.
const LABEL_INPUTS = new Set(["button", "submit", "reset", "image", "checkbox", "radio", "range", "color"]);

/// Every field's text leaves the copy: a text input's `value` attribute (a controlled input's,
/// which carries what it shows, such as an API key in a sign-in field) and a textarea's text,
/// in the markup and in its shadow roots' templates. The chat's composer draft is the prompt
/// editor's own markup, not a field, so the copy still shows it.
function scrubFields(root: ParentNode): void {
  for (const field of Array.from(root.querySelectorAll("input, textarea"))) {
    if (field.tagName === "TEXTAREA") field.textContent = "";
    else if (!LABEL_INPUTS.has((field.getAttribute("type") ?? "text").toLowerCase())) field.removeAttribute("value");
  }
  for (const template of Array.from(root.querySelectorAll("template"))) scrubFields(template.content);
}

function stripHandlers(root: ParentNode): void {
  // By shape, not `instanceof` (the page's realm is not always this module's).
  const self = "attributes" in root ? [root as Element] : [];
  const elements = [...self, ...Array.from(root.querySelectorAll("*"))];
  for (const element of elements) {
    for (const attribute of Array.from(element.attributes))
      if (/^on/i.test(attribute.name)) element.removeAttribute(attribute.name);
    if (element.tagName === "TEMPLATE") stripHandlers((element as HTMLTemplateElement).content);
  }
}

/// The theme's own sheet (WebTheme's bootstrap), which `<html>` already carries under the copy.
const THEME_STYLE_ID = "cmux-theme";

/// The page's sheets beside its main one, in order: `<style>` elements (the person's theme.css,
/// a chunk's rules) and the document's adopted sheets, each cut to the rules the copy can use
/// (usedRules.ts).
function pageStyles(doc: Document, used: UsedNames, alsoNamed: string): string[] {
  const sheets: CSSStyleSheet[] = [];
  for (const style of Array.from(doc.querySelectorAll("style"))) {
    if (style.id === PAGE_STYLE_ID || style.id === THEME_STYLE_ID || style.closest("#root")) continue;
    if (style.sheet) sheets.push(style.sheet);
  }
  sheets.push(...(doc.adoptedStyleSheets ?? []));
  return sheets.map((sheet) => usedRules(sheet, used, alsoNamed)).filter((text) => text.length > 0);
}

/// Why the last ``captureSnapshot`` gave none (empty when it gave one), for the page's writes record
/// and the host's (live.ts).
let missed = "";
export function captureMiss(): string {
  return missed;
}

/// The snapshot of `doc` as it shows now, drawn in the theme `theme` keys, or undefined when it
/// shows no chat or the visible window is larger than ``SNAPSHOT_MAX_CHARS``.
export function captureSnapshot(doc: Document, theme: string): ChatSnapshot | undefined {
  const view = doc.defaultView;
  const live = doc.getElementById("root");
  missed = "no chat drawn";
  if (!theme || !view || !live || !doc.body || live.childElementCount === 0) return undefined;
  const viewHeight = view.innerHeight;
  const liveElements = Array.from(live.querySelectorAll("*"));
  const plans = liveElements.map((element) => planFor(element, viewHeight));
  const copy = live.cloneNode(true) as HTMLElement;
  // The live root is held at opacity 0 while a drawn copy covers it (paint.ts, until the swap): a
  // write in that time must not keep an invisible root.
  copy.style.removeProperty("opacity");
  if (copy.getAttribute("style") === "") copy.removeAttribute("style");
  const copyElements = Array.from(copy.querySelectorAll("*"));
  missed = "the copy's elements differ";
  if (copyElements.length !== liveElements.length) return undefined;
  const sheets = new Map<CSSStyleSheet, number>();
  copyElements.forEach((element, index) => {
    const plan = plans[index];
    if (!plan) return;
    if (plan.drop) {
      element.remove();
      return;
    }
    if (plan.scroll) element.setAttribute(SNAPSHOT_SCROLL_ATTRIBUTE, plan.scroll);
    if (plan.checked) element.setAttribute("checked", "");
    if (plan.shadow) {
      const adopted = plan.shadow.adoptedStyleSheets ?? [];
      const indexes = adopted.map((sheet) => {
        let at = sheets.get(sheet);
        if (at === undefined) {
          at = sheets.size;
          sheets.set(sheet, at);
        }
        return at;
      });
      if (indexes.length > 0) element.setAttribute(SNAPSHOT_SHEETS_ATTRIBUTE, indexes.join(","));
      element.prepend(shadowTemplate(doc, plan.shadow));
    }
  });
  for (const node of Array.from(copy.querySelectorAll(DROPPED))) node.remove();
  stripHandlers(copy);
  scrubFields(copy);
  const html = copy.outerHTML;
  const sheetTexts = Array.from(sheets.keys(), sheetText);
  const root = attributesOf(doc.documentElement);
  const body = attributesOf(doc.body);
  const used = usedNames([copy, ...Array.from(copy.querySelectorAll("*")), doc.documentElement, doc.body]);
  const styles = pageStyles(doc, used, `${html}\n${root.style ?? ""}\n${body.style ?? ""}`);
  const total = [html, ...sheetTexts, ...styles].reduce((sum, text) => sum + text.length, 0);
  missed = `too large: markup ${html.length}, shadow sheets ${sheetTexts.length} of ${sheetTexts.reduce((sum, text) => sum + text.length, 0)}, page sheets ${styles.length} of ${styles.reduce((sum, text) => sum + text.length, 0)} chars`;
  if (total > SNAPSHOT_MAX_CHARS) return undefined;
  missed = "";
  return {
    v: SNAPSHOT_VERSION,
    html,
    width: view.innerWidth,
    height: view.innerHeight,
    root,
    body,
    sheets: sheetTexts,
    styles,
    theme,
    savedAt: Date.now(),
  };
}
