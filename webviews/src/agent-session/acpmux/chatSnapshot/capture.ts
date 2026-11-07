// Writes what the chat's page shows now as a snapshot (shared.ts): `<main id="root">` as drawn, with
// the transcript rows out of view left out, so its size is the visible window's and not the
// transcript's. Reads first (every rect and scroll offset), then edits only the detached copy, so
// it forces at most the one layout the page already needs for its next frame.
import {
  attributesOf,
  SNAPSHOT_MAX_CHARS,
  SNAPSHOT_SCROLL_ATTRIBUTE,
  SNAPSHOT_SHEETS_ATTRIBUTE,
  SNAPSHOT_VERSION,
  type ChatSnapshot,
} from "./shared";

/// The transcript's rows: absolutely placed, so leaving one out moves no other.
const ROW_SELECTOR = ".acpmux-row";
/// What a copy never carries: script, frames, and the page's own media (a copy cannot play it).
const DROPPED = "script, iframe, object, embed, frame, frameset, video, audio, canvas";

type Plan = { drop: boolean; scroll?: string; value?: string; checked?: boolean; shadow?: ShadowRoot };

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
  if (tag === "TEXTAREA" || tag === "INPUT") {
    const field = element as HTMLInputElement;
    plan ??= { drop: false };
    // Typed text is a property, not markup; a password never leaves its field.
    if (field.type !== "password") plan.value = field.value;
    if (tag === "INPUT") plan.checked = field.checked;
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

function stripHandlers(root: Element): void {
  for (const element of [root, ...Array.from(root.querySelectorAll("*"))])
    for (const attribute of Array.from(element.attributes))
      if (/^on/i.test(attribute.name)) element.removeAttribute(attribute.name);
}

/// The snapshot of `doc` as it shows now, or undefined when it shows no chat or the visible window
/// is larger than ``SNAPSHOT_MAX_CHARS``.
export function captureSnapshot(doc: Document): ChatSnapshot | undefined {
  const view = doc.defaultView;
  const live = doc.getElementById("root");
  if (!view || !live || !doc.body || live.childElementCount === 0) return undefined;
  const viewHeight = view.innerHeight;
  const liveElements = Array.from(live.querySelectorAll("*"));
  const plans = liveElements.map((element) => planFor(element, viewHeight));
  const copy = live.cloneNode(true) as HTMLElement;
  const copyElements = Array.from(copy.querySelectorAll("*"));
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
    if (plan.value !== undefined) {
      if (element.tagName === "TEXTAREA") element.textContent = plan.value;
      else element.setAttribute("value", plan.value);
    }
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
  const html = copy.outerHTML;
  const sheetTexts = Array.from(sheets.keys(), sheetText);
  const total = html.length + sheetTexts.reduce((sum, text) => sum + text.length, 0);
  if (total > SNAPSHOT_MAX_CHARS) return undefined;
  return {
    v: SNAPSHOT_VERSION,
    html,
    width: view.innerWidth,
    height: view.innerHeight,
    root: attributesOf(doc.documentElement),
    body: attributesOf(doc.body),
    sheets: sheetTexts,
    savedAt: Date.now(),
  };
}
