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
  SNAPSHOT_AGENT_THEME_GLOBAL,
  SNAPSHOT_THEME_GLOBAL,
  shadowSelector,
  type ChatSnapshot,
  type SnapshotAttributes,
  CHROME_ONLY_RULE,
  fitsChromeOnly,
  SNAPSHOT_CHROME_ONLY_ATTRIBUTE,
} from "./shared";
import { agentThemeColors } from "../../shared/themeVariables";
import type { AgentSessionTheme } from "../../shared/types";

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

/// The `data-*` look attributes the host's theme apply owns on `<html>` (WebTheme.swift's document-start
/// apply: each set when the theme has it, a decoration slot removed when the theme leaves it empty).
const HOST_LOOK_ATTRIBUTES = new Set([
  "data-scrollers",
  "data-status-indicators",
  "data-working-look",
  "data-cmux-motion",
  "data-glass",
  "data-cmux-font-smoothing",
]);
const HOST_DECORATION_PREFIX = "data-cmux-decoration-";

export function isHostLookAttribute(name: string): boolean {
  return HOST_LOOK_ATTRIBUTES.has(name) || name.startsWith(HOST_DECORATION_PREFIX);
}

/// The theme the host gave this document before page code ran (WebTheme's document-start apply: the
/// `--cmux-*` variables and `color-scheme` on `<html>`, and its `data-*` look attributes), over the
/// copy's own: the copy draws in the colors the live page draws in, so the swap changes no color, and a
/// variable this build added is there for this build's sheet. Under the theme the copy was written in
/// the values are the same. A look attribute the copy's theme set and the live one leaves out goes too
/// (an old theme's working look or decoration drew its borders and motion until the swap); the copy's
/// page-state attributes, which the host never sets, stay as the copy laid out with them. `agent` is the
/// pane theme the host serves beside the copy (shared.ts `SNAPSHOT_AGENT_THEME_GLOBAL`): the page sets
/// its `--agent-*` colors only after its handshake, so the copy takes them from it, set or cleared as the
/// page's own theme apply would (theme.ts), and draws the live theme's colors from its first frame.
export function layerHostTheme(stand: HTMLElement, root: HTMLElement, agent?: unknown): void {
  for (let index = 0; index < root.style.length; index += 1) {
    const name = root.style.item(index);
    if (name.startsWith("--")) stand.style.setProperty(name, root.style.getPropertyValue(name));
  }
  if (agent && typeof agent === "object" && !Array.isArray(agent))
    for (const [variable, value] of agentThemeColors(agent as Partial<AgentSessionTheme>)) {
      if (value === undefined) stand.style.removeProperty(variable);
      else stand.style.setProperty(variable, value);
    }
  if (root.style.colorScheme) stand.style.colorScheme = root.style.colorScheme;
  for (const attribute of Array.from(stand.attributes))
    if (isHostLookAttribute(attribute.name) && !root.hasAttribute(attribute.name))
      stand.removeAttribute(attribute.name);
  for (const attribute of Array.from(root.attributes))
    if (attribute.name.startsWith("data-")) stand.setAttribute(attribute.name, attribute.value);
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
  // Reads before every write: one layout for the whole copy. The copy's shadow roots too (capture.ts
  // `shadowTemplate` keeps their offsets).
  const scrolled: HTMLElement[] = [];
  const collect = (scope: ParentNode) => {
    scrolled.push(...Array.from(scope.querySelectorAll<HTMLElement>(`[${SNAPSHOT_SCROLL_ATTRIBUTE}]`)));
    for (const element of Array.from(scope.querySelectorAll("*"))) if (element.shadowRoot) collect(element.shadowRoot);
  };
  collect(root);
  // One scrolled to its end (the transcript at its latest row) stays there in a window of another
  // height, as the live page keeps it: at its saved top, the copy drew every row that far from where the
  // live page then drew it (Leo, 2026-11-16, after a restart: "it layout shifted as it drew").
  const marks = scrolled.map((element) => (element.getAttribute(SNAPSHOT_SCROLL_ATTRIBUTE) ?? "").split(","));
  const ends = scrolled.map((element, at) =>
    marks[at]![2] === "end" ? element.scrollHeight - element.clientHeight : undefined,
  );
  scrolled.forEach((element, at) => {
    const [top, left] = marks[at]!.map(Number);
    element.scrollTop = ends[at] ?? (top || 0);
    element.scrollLeft = left || 0;
  });
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
/// written in another look or theme, or when the engine lacks what the copy needs; written for another
/// viewport, its chrome only (shared.ts `fitsChromeOnly`).
///
/// The copy links the page's own sheet in its shadow root, and beside it the page's root rules
/// rewritten for the shadow tree (its link's `data-copy`): each chat page of the renderer used to parse
/// a constructed copy of the whole page sheet (bench/chat-pages-memory.bench.ts, CSS=inline), where the
/// links reuse the renderer's one parse. A link finishes in a later task even when the sheet is parsed
/// already, so the copy is laid out hidden and shows once both loaded, before the next frame. Hidden is
/// `opacity:0` on the host, not `visibility:hidden`: visibility inherits, so showing restyled every element
/// of the copy (11-14 ms of the 110 ms to its first paint, bench/chat-floor.bench.ts); opacity is the host's own.
export function paintSnapshot(
  doc: Document,
  snapshot: ChatSnapshot | null | undefined,
  events: PaintEvents = {},
): boolean {
  const view = doc.defaultView;
  const live = doc.getElementById("root");
  const pageSheet = doc.getElementById(PAGE_STYLE_ID);
  if (!view || !live || !doc.body || !snapshot) return false;
  // Written at another size in the same theme: the pane's chrome draws (the composer with its hat and
  // pills, the header), laid out at this size; the transcript's rows do not (shared.ts `fitsChromeOnly`).
  const chromeOnly = !fitsDocument(snapshot, doc) && fitsChromeOnly(snapshot, doc);
  if (!chromeOnly && !fitsDocument(snapshot, doc)) return false;
  const copySheet = pageSheet instanceof view.HTMLLinkElement && pageSheet.href ? pageSheet.dataset.copy : undefined;
  if (!copySheet) return false;
  const styles = snapshot.styles.map((text) => sheetOf(view, text));
  const still = sheetOf(view, BASE + STILL + (chromeOnly ? CHROME_ONLY_RULE : ""));
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
    "position:fixed;inset:0;display:block;z-index:var(--layer-debug);pointer-events:none;contain:strict;margin:0;padding:0;border:0;opacity:0";
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
  // Only under another theme: under the one it was written in, the copy's root already holds the live
  // page's look attributes and variables as it drew, and the host's document-start ones are what the page
  // replaces with its own once it runs. Suspected cause of the copy's trust ask drawing 4 px taller than the
  // live one (95 against 91 in the relaunch-shift bench, where the swap never matched); the swap's report
  // (swapDiff.ts `copyAsk`/`liveAsk`) says.
  if ((view as unknown as Record<string, unknown>)[SNAPSHOT_THEME_GLOBAL] !== snapshot.theme)
    layerHostTheme(
      html,
      doc.documentElement,
      (view as unknown as Record<string, unknown>)[SNAPSHOT_AGENT_THEME_GLOBAL],
    );
  html.classList.add(SNAPSHOT_ROOT_CLASS);
  const body = doc.createElement(SNAPSHOT_BODY_TAG);
  setAttributes(body, snapshot.body);
  if (chromeOnly) body.setAttribute(SNAPSHOT_CHROME_ONLY_ATTRIBUTE, "");
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
    host.style.removeProperty("opacity");
    live.style.opacity = "0";
    restoreScroll(body);
    globals[SNAPSHOT_SHOWN_GLOBAL] = { at: view.performance.now(), ...(chromeOnly ? { chromeOnly: true } : {}) };
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
