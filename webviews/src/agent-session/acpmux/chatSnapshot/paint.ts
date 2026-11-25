// Draws a chat's snapshot (shared.ts) in the document's first frames, before the bundle runs: the
// page's first classic script calls this (boot.ts). The copy lives in a shadow root, so none of the
// page's own code and selectors find it, under the page's own `pane.css` and `pane-copy.css` (its
// `html`, `body` and `:root` rules rewritten for the shadow tree at build time); the live page's root is
// clear under it until the swap
// (live.ts). The copy takes no input: clicks, scrolls and focus go through it to the live page, and
// typing before the live composer is up waits in the host's key queue (PageInputReadiness), as it does
// with no snapshot.
import {
  fitsDocument,
  PAGE_STYLE_ID,
  SNAPSHOT_BODY_TAG,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_HTML_TAG,
  SNAPSHOT_MISS_GLOBAL,
  SNAPSHOT_ROOT_CLASS,
  SNAPSHOT_SCROLL_ATTRIBUTE,
  SNAPSHOT_SHEETS_ATTRIBUTE,
  SNAPSHOT_SHOWN_GLOBAL,
  shadowSelector,
  type ChatSnapshot,
  type SnapshotAttributes,
} from "./shared";

/// The copy shows its final frame: what was running when it was written ends at once, as the
/// motion-off rule ends it (WebTheme `data-cmux-motion="off"`), so nothing in it enters again.
const STILL =
  "*,*::before,*::after{transition:none!important;animation-duration:0s!important;" +
  "animation-delay:0s!important;animation-iteration-count:1!important}";
/// The stand-ins are blocks the size of the viewport. `<html>` and `<body>` already paint their own
/// backgrounds under the copy, so the stand-ins paint none (a translucent one would paint twice).
const BASE =
  `${SNAPSHOT_HTML_TAG},${SNAPSHOT_BODY_TAG}{display:block;background:transparent!important}` +
  `${SNAPSHOT_HTML_TAG}{width:100%;height:100%;overflow:hidden}`;

function rewrite(rules: CSSRuleList): void {
  for (const rule of Array.from(rules)) {
    const style = rule as CSSStyleRule;
    const selector = style.selectorText;
    if (typeof selector === "string" && /html|body|:root/.test(selector)) {
      const next = shadowSelector(selector);
      if (next !== selector) style.selectorText = next;
    }
    const nested = (rule as CSSGroupingRule).cssRules;
    if (nested && nested.length > 0) rewrite(nested);
  }
}

/// One constructed sheet of `text`, or undefined when this engine cannot make one.
function sheetOf(view: Window, text: string): CSSStyleSheet | undefined {
  const Sheet = (view as Window & { CSSStyleSheet?: typeof CSSStyleSheet }).CSSStyleSheet;
  if (!Sheet) return undefined;
  try {
    const sheet = new Sheet();
    sheet.replaceSync(text);
    return sheet;
  } catch {
    return undefined;
  }
}

function setAttributes(element: Element, attributes: SnapshotAttributes): void {
  for (const [name, value] of Object.entries(attributes)) {
    if (name === "id" || /^on/i.test(name)) continue;
    try {
      element.setAttribute(name, value);
    } catch {
      // A name the markup allowed but setAttribute does not: left out.
    }
  }
}

/// Script, frames and handlers out of the parsed copy: it draws, it never runs anything.
function inertCopy(root: ParentNode): void {
  for (const node of Array.from(root.querySelectorAll("script, iframe, object, embed, frame, frameset"))) node.remove();
  for (const element of Array.from(root.querySelectorAll("*")))
    for (const attribute of Array.from(element.attributes))
      if (/^on/i.test(attribute.name)) element.removeAttribute(attribute.name);
}

/// Declarative shadow roots of the copy (an edit card's diff) get their adopted sheets.
function adoptShadowSheets(root: ParentNode, sheets: CSSStyleSheet[]): void {
  for (const element of Array.from(root.querySelectorAll(`[${SNAPSHOT_SHEETS_ATTRIBUTE}]`))) {
    const shadow = element.shadowRoot;
    if (shadow) {
      const picked = (element.getAttribute(SNAPSHOT_SHEETS_ATTRIBUTE) ?? "")
        .split(",")
        .map((index) => sheets[Number(index)])
        .filter((sheet): sheet is CSSStyleSheet => !!sheet);
      shadow.adoptedStyleSheets = picked;
      adoptShadowSheets(shadow, sheets);
    }
  }
}

function restoreScroll(root: ParentNode): void {
  // Reads after every write: one layout for the whole copy. The copy's shadow roots too (capture.ts
  // `shadowTemplate` keeps their offsets).
  const scrolled: HTMLElement[] = [];
  const collect = (scope: ParentNode) => {
    scrolled.push(...Array.from(scope.querySelectorAll<HTMLElement>(`[${SNAPSHOT_SCROLL_ATTRIBUTE}]`)));
    for (const element of Array.from(scope.querySelectorAll("*"))) if (element.shadowRoot) collect(element.shadowRoot);
  };
  collect(root);
  for (const element of scrolled) {
    const [top, left] = (element.getAttribute(SNAPSHOT_SCROLL_ATTRIBUTE) ?? "").split(",").map(Number);
    element.scrollTop = top || 0;
    element.scrollLeft = left || 0;
  }
}

/// What the boot script hears of a copy it asked for (boot.ts).
export type PaintEvents = {
  /// Asked once the copy's sheet loaded, before it shows: false when the live page drew the chat
  /// meanwhile (the copy then goes, unseen).
  wanted?: () => boolean;
  /// The copy shows.
  shown?: () => void;
};

/// Draws `snapshot` over `doc`'s live root; true when it will. Nothing when there is none, when it was
/// written for another viewport, look or theme, or when the engine lacks what the copy needs.
///
/// The copy links the page's own sheet in its shadow root, and beside it the page's root rules
/// rewritten for the shadow tree (its link's `data-copy`): each chat page of the renderer used to parse
/// a constructed copy of the whole page sheet (bench/chat-pages-memory.bench.ts, CSS=inline), where the
/// links reuse the renderer's one parse. A link finishes in a later task even when the sheet is parsed
/// already, so the copy is laid out hidden and shows once both loaded, before the next frame.
export function paintSnapshot(
  doc: Document,
  snapshot: ChatSnapshot | null | undefined,
  events: PaintEvents = {},
): boolean {
  const view = doc.defaultView;
  const live = doc.getElementById("root");
  const pageSheet = doc.getElementById(PAGE_STYLE_ID);
  if (!view || !live || !doc.body || !snapshot || !fitsDocument(snapshot, doc)) return false;
  const copySheet = pageSheet instanceof view.HTMLLinkElement && pageSheet.href ? pageSheet.dataset.copy : undefined;
  if (!copySheet) return false;
  const styles = snapshot.styles.map((text) => sheetOf(view, text));
  const still = sheetOf(view, BASE + STILL);
  if (!still || styles.some((sheet) => !sheet)) return false;
  try {
    for (const sheet of styles) rewrite(sheet!.cssRules);
  } catch {
    return false;
  }
  const host = doc.createElement(SNAPSHOT_HOST_TAG);
  host.setAttribute("inert", "");
  host.setAttribute("aria-hidden", "true");
  host.style.cssText =
    "position:fixed;inset:0;display:block;z-index:var(--layer-debug);pointer-events:none;contain:strict;margin:0;padding:0;border:0;visibility:hidden";
  const shadow = host.attachShadow({ mode: "open" });
  const sheets = snapshot.sheets.map((text) => sheetOf(view, text)).filter((s): s is CSSStyleSheet => !!s);
  // The shadow root's own sheets cascade before its adopted ones: the page's rules (with its root
  // rules rewritten), then the copy's other sheets, then the still rule, as the page had them.
  const pageHref = (pageSheet as HTMLLinkElement).href;
  const links = [pageHref, new URL(copySheet, pageHref).href].map((href) => {
    const link = doc.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    return link;
  });
  shadow.adoptedStyleSheets = [...(styles as CSSStyleSheet[]), still];
  const html = doc.createElement(SNAPSHOT_HTML_TAG);
  setAttributes(html, snapshot.root);
  html.classList.add(SNAPSHOT_ROOT_CLASS);
  const body = doc.createElement(SNAPSHOT_BODY_TAG);
  setAttributes(body, snapshot.body);
  // Declarative shadow roots in the markup become shadow roots (setHTMLUnsafe); without it, plain markup.
  const parse = (body as Element & { setHTMLUnsafe?: (html: string) => void }).setHTMLUnsafe;
  if (parse) parse.call(body, snapshot.html);
  else body.innerHTML = snapshot.html;
  inertCopy(body);
  adoptShadowSheets(body, sheets);
  html.appendChild(body);
  shadow.append(...links, html);
  const globals = view as unknown as Record<string, unknown>;
  let loading = links.length;
  const failed = () => {
    if (!host.isConnected) return;
    host.remove();
    globals[SNAPSHOT_MISS_GLOBAL] = "the copy's sheet did not load";
  };
  const loaded = () => {
    // Gone already: the live page took over, a press ended it (live.ts), or a sheet failed.
    if (--loading > 0 || !host.isConnected) return;
    if (events.wanted && !events.wanted()) {
      host.remove();
      globals[SNAPSHOT_MISS_GLOBAL] = "late: the page drew the chat first";
      return;
    }
    // The live root lays out under the copy, unseen until the swap (live.ts); a press on the copy ends it
    // and reaches nothing under it (live.ts `reportChatSnapshot`). Both in this task: one frame shows it.
    host.style.removeProperty("visibility");
    live.style.opacity = "0";
    restoreScroll(body);
    globals[SNAPSHOT_SHOWN_GLOBAL] = { at: view.performance.now() };
    view.performance.mark?.("cmux-chat:snapshot-paint");
    events.shown?.();
  };
  for (const link of links) {
    link.addEventListener("load", loaded, { once: true });
    link.addEventListener("error", failed, { once: true });
  }
  doc.body.appendChild(host);
  return true;
}
