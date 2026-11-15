// l10n-allow-file: English patterns the journey reads in rendered text, never shown.
//
// The first-user journey's "no busted state" rules (scripts/first-user-journey/run.mjs). Each is named, so a run's reds group by
// class. The DOM rules run inside the page (scripts/first-user-journey/run.mjs imports this module through the dev server), and
// rules.test.ts runs them on hand-made documents. Clicks are judged with the Cloud ergonomics
// measurement's own helpers (src/agent-session/acpmux/cloudErgonomics/classify.ts): what counts as a
// control, what a person reads, and what words point outside the app.
import { controlsIn, outOfAppWords, visibleText } from "../../agent-session/acpmux/cloudErgonomics/classify";

export const RULES = [
  "error-without-next-step",
  "raw-error-code",
  "dead-button",
  "permanent-spinner",
  "layout-break",
  "console-error",
  "crash",
] as const;
export type Rule = (typeof RULES)[number];
export type Red = { rule: Rule; detail: string };

/// Text a person reads as a code or a crash, not as words. Each with the name a red reports.
const RAW: readonly [string, RegExp][] = [
  ["errno", /\bE(?:CONNREFUSED|CONNRESET|NOTFOUND|TIMEDOUT|AI_AGAIN|HOSTUNREACH|PIPE|ACCES|PERM|NOENT|NOSPC)\b/],
  [
    "http status",
    /\bHTTP\/?\d?(?:\.\d)?\s*[45]\d\d\b|\b(?:status|code)[:= ]+[45]\d\d\b|\b[45]\d\d (?:Bad Request|Unauthorized|Forbidden|Not Found|Too Many Requests|Internal Server Error|Bad Gateway|Service Unavailable)\b/i,
  ],
  ["Error: prefix", /(?:^|[\s(])(?:[A-Z][A-Za-z]*)?Error: /],
  [
    "error type name",
    /\b(?:TypeError|ReferenceError|SyntaxError|RangeError|ProtocolError|NativeError|AbortError|DOMException|[A-Z][A-Za-z]+Exception)\b/,
  ],
  ["stack trace", /\bat [\w.$<>]+ \(?[^\s()]+:\d+:\d+\)?/],
  ["JSON blob", /[{[]\s*"[A-Za-z_]+"\s*:/],
  ["undefined/null", /(?:^|[\s:"'(=])(?:undefined|null|NaN)(?=$|[\s,.;:)"'])/],
  ["[object Object]", /\[object [A-Z][a-z]+\]/],
  ["JSON-RPC code", /(?:^|\s)-32\d{3}\b/],
  // A dotted or snake-case machine code (`auth.signed_out`, `transport.harness_not_confirmed`,
  // `rate_limit_error`): two lowercase words joined by `_`, or a dot then such a word.
  [
    "machine code",
    /\b[a-z]+(?:\.[a-z]+)*\.[a-z]+_[a-z_]+\b|\b[a-z]+_[a-z]+_(?:error|exceeded|required|failed|not_found)\b/,
  ],
];

/// The first raw code in `text`, as `name: match`, or undefined.
export function rawErrorCode(text: string): string | undefined {
  for (const [name, pattern] of RAW) {
    const hit = pattern.exec(text);
    if (hit) return `${name}: ${hit[0].trim()}`;
  }
  return undefined;
}

/// Words that say something went wrong.
const ERROR_WORDS =
  /\b(?:failed|failure|error|couldn['’]t|could not|can['’]t|cannot|unable to|not (?:signed|logged) in|sign(?:ed)? out|expired|limit (?:reached|exceeded)|hit your (?:usage )?limit|usage limit|quota|not installed|unavailable|unreachable|refused|went wrong|not connected|not found|unknown harness)\b/i;
export function saysError(text: string): boolean {
  return ERROR_WORDS.test(text);
}

/// A status that says the thing beside it cannot be used yet.
const STATUS =
  /^(?:not installed|not signed in|signed out|sign-in expired|expired|unavailable|offline|not connected)\.?$/i;

/// Where errors are drawn: alerts, and elements whose class or data names an error, failure, problem or
/// warning. Outermost only: a card's own message is part of the card.
const ERROR_REGION =
  '[role="alert"], [data-error], [data-failure], [aria-invalid="true"], [class*="error" i], [class*="failure" i], [class*="problem" i], [class*="warning" i], [class*="notice" i]';
/// Text that is not the page's own words: what a person typed or an agent wrote, code, and raw details.
const NOT_PAGE_WORDS = [
  "pre",
  "code",
  "textarea",
  "input",
  "[contenteditable]",
  ".cv-user",
  ".cv-agent",
  ".cv-markdown",
  ".markdown",
  "[data-raw-error]",
];

export type ErrorRegion = { text: string; controls: number; pointsOut?: string };

/// Every visible error region under `root` that says something went wrong, with what it offers.
export function errorRegions(root: Element): ErrorRegion[] {
  // A status line that says a thing cannot be used ("Not installed", "Signed out") is an error where
  // it stands too, whatever its class: a row that says so needs its way forward beside it.
  const statuses = [...root.querySelectorAll("span, div, p, small, li")].filter(
    (node) => node.children.length === 0 && STATUS.test((node.textContent ?? "").trim()) && shown(node),
  );
  const regions = [...root.querySelectorAll(ERROR_REGION), ...statuses].filter((node) => shown(node) && onScreen(node));
  const outer = regions.filter((node) => !regions.some((other) => other !== node && other.contains(node)));
  const found: ErrorRegion[] = [];
  for (const region of outer) {
    // A region is judged with its card: the nearest ancestor that holds a control or more words.
    const card = cardOf(region);
    const text = visibleText(card, NOT_PAGE_WORDS);
    if (!text || !saysError(visibleText(region, NOT_PAGE_WORDS))) continue;
    found.push({
      text: text.slice(0, 200),
      controls: controlsIn([card]).length,
      pointsOut: outOfAppWords([card]),
    });
  }
  return found;
}

/// The region, or its parent while the region is a bare label inside a small card (the error's words
/// in one element, its Sign in button beside them).
function cardOf(region: Element): Element {
  let node = region;
  for (let depth = 0; depth < 3 && node.parentElement; depth += 1) {
    if (controlsIn([node]).length > 0) return node;
    const parent = node.parentElement;
    if (parent === node.ownerDocument.body || visibleText(parent).length > 600) return node;
    // A list of rows: the parent holds other rows' statuses, so its controls are theirs, not this row's.
    const leaves = [...parent.querySelectorAll("*")].filter(
      (leaf) =>
        leaf.children.length === 0 &&
        (STATUS.test((leaf.textContent ?? "").trim()) || saysError(leaf.textContent ?? "")),
    );
    if (leaves.length > 1 && !leaves.every((leaf) => region.contains(leaf))) return node;
    node = parent;
  }
  return node;
}

/// error-without-next-step: an error that offers no control and names no command, page or place to go.
/// Instructions in words count (`Run claude auth login`, "in Settings"), as classify.ts counts them.
export function errorWithoutNextStep(regions: readonly ErrorRegion[]): Red[] {
  return regions
    .filter((region) => region.controls === 0 && !region.pointsOut && !INSTRUCTION.test(region.text))
    .map((region) => ({ rule: "error-without-next-step" as const, detail: region.text }));
}
const INSTRUCTION =
  /\b(?:try again|retry|sign in|log in|install|upgrade|resets?|wait|switch to|choose|pick|open|run|add|enable|check)\b/i;

/// raw-error-code: the page's own words (never a person's or an agent's text, code, or Details) show a code.
export function rawErrorCodes(root: Element): Red[] {
  const text = visibleText(root, NOT_PAGE_WORDS);
  const hit = rawErrorCode(text);
  return hit ? [{ rule: "raw-error-code", detail: `${hit} in "${around(text, hit)}"` }] : [];
}

function around(text: string, hit: string): string {
  const needle = hit.slice(hit.indexOf(": ") + 2);
  const at = Math.max(0, text.indexOf(needle));
  return text.slice(Math.max(0, at - 60), at + needle.length + 60);
}

/// What one click changed, as run.mjs observes it around the click.
export type ClickEffect = {
  dom: boolean;
  url: boolean;
  focus: boolean;
  clipboard: boolean;
  rpc: string[];
  host: string[];
  popup: boolean;
};

/// dead-button: a click that changed nothing a person or the app could see. A control already in the
/// state it sets (the selected tab, the chosen filter) has nothing to change.
export function deadButton(label: string, effect: ClickEffect, selected = false): Red[] {
  if (selected) return [];
  const any =
    effect.dom ||
    effect.url ||
    effect.focus ||
    effect.clipboard ||
    effect.popup ||
    effect.rpc.length ||
    effect.host.length;
  return any
    ? []
    : [
        {
          rule: "dead-button",
          detail: `"${label}" changed nothing (DOM, route, focus, clipboard, RPC)`,
        },
      ];
}

/// dead-button for a disabled control: it needs a visible reason (a tooltip, a description, or words beside it).
export function disabledWithoutReason(control: Element): Red[] {
  const disabled = (control as HTMLButtonElement).disabled || control.getAttribute("aria-disabled") === "true";
  if (!disabled || !shown(control)) return [];
  // A form's commit buttons wait for something to commit: "nothing to save yet" needs no words.
  if (COMMIT.test(labelOf(control))) return [];
  const reason =
    REASON_WORDS.test(visibleText(control)) ||
    // The row's own status says why ("web Ready" beside a disabled Build).
    ROW_STATUS.test(visibleText(control.closest('li, tr, [role="row"], .row') ?? control)) ||
    control.getAttribute("title") ||
    control.getAttribute("data-tooltip") ||
    control.getAttribute("aria-describedby") ||
    control.closest("[title], [data-tooltip]")?.getAttribute("title") ||
    control.parentElement?.querySelector('[role="tooltip"], .ui-tooltip');
  return reason ? [] : [{ rule: "dead-button", detail: `"${labelOf(control)}" is disabled with no reason shown` }];
}

/// Undo and Redo with no history, and a Reset when nothing differs from the default, follow the
/// platform convention: disabled means "nothing to do", which the control's own name says.
const COMMIT =
  /^(?:save|save changes|revert|apply|discard|reset(?: [a-z ]+)?|cancel|send|submit|done|update all|undo|redo)$/i;

/// A disabled control whose own words say why (a row that reads "Offline", "Not installed").
const REASON_WORDS =
  /\b(?:offline|unavailable|not installed|not signed in|signed out|requires?|needs?|coming soon|disabled|managed by|read[- ]only|no [a-z]+ (?:yet|to))\b/i;

/// A status a row shows that explains its disabled actions.
const ROW_STATUS = /\b(?:ready|building|running|in progress|up to date|already [a-z]+)\b/i;

const SPINNER =
  '[role="progressbar"], [aria-busy="true"], [class*="spinner" i], [class*="loading" i], [class*="skeleton" i], [data-loading="true"]';
/// The loading indicators a person can see now.
export function spinners(root: Element): string[] {
  const found = [...root.querySelectorAll(SPINNER)]
    .filter((node) => shown(node) && !node.closest('[aria-hidden="true"]'))
    .map((node) => labelOf(node) || describe(node));
  const words = [...root.querySelectorAll("body *")].filter(
    (node) =>
      node.children.length === 0 &&
      /^(?:Loading|Checking|Connecting|Starting)(?:…|\.{3}|\s.{0,30}(?:…|\.{3}))?$/.test(
        (node.textContent ?? "").trim(),
      ) &&
      shown(node),
  );
  // Words count only as a status ("Loading…", "Checking for updates…"), never a heading
  // ("Loading Indicator" names a setting).
  return [...found, ...words.map((node) => (node.textContent ?? "").trim())];
}

/// permanent-spinner: loading indicators still shown after the page has had 10 s with the mock answering.
export function permanentSpinners(still: readonly string[]): Red[] {
  return still.map((what) => ({
    rule: "permanent-spinner" as const,
    detail: `still loading after 10 s: ${what}`,
  }));
}

/// layout-break at one viewport: a page wider than the window, controls outside it, controls drawn
/// over one another, and text cut off without an ellipsis.
export function layoutBreaks(doc: Document, viewport: { width: number; height: number }): Red[] {
  const reds: Red[] = [];
  const size = `${viewport.width}x${viewport.height}`;
  const scroller = doc.scrollingElement ?? doc.documentElement;
  if (scroller.scrollWidth > viewport.width + 1)
    reds.push({
      rule: "layout-break",
      detail: `${size}: the page scrolls sideways (${scroller.scrollWidth}px wide)`,
    });
  const controls = [
    ...doc.querySelectorAll('button, a[href], [role="button"], [role="menuitem"], [role="tab"], input, select'),
  ].filter((node) => shown(node) && !inScroller(node));
  for (const node of controls) {
    const box = node.getBoundingClientRect();
    if (box.right > viewport.width + 1 || box.left < -1) {
      reds.push({
        rule: "layout-break",
        detail: `${size}: "${labelOf(node)}" is outside the window`,
      });
      break;
    }
  }
  const boxes = controls.map((node) => ({ node, box: node.getBoundingClientRect() }));
  outer: for (let i = 0; i < boxes.length; i += 1)
    for (let j = i + 1; j < boxes.length; j += 1) {
      const a = boxes[i]!;
      const b = boxes[j]!;
      if (a.node.contains(b.node) || b.node.contains(a.node)) continue;
      const overlap = intersection(a.box, b.box);
      const smaller = Math.min(area(a.box), area(b.box));
      if (smaller > 0 && overlap / smaller > 0.5 && sameLayer(a.node, b.node)) {
        reds.push({
          rule: "layout-break",
          detail: `${size}: "${labelOf(a.node)}" and "${labelOf(b.node)}" overlap`,
        });
        break outer;
      }
    }
  for (const node of doc.querySelectorAll("button, a, h1, h2, h3, label, [role='menuitem'], [role='tab']")) {
    if (!shown(node) || node.children.length > 2) continue;
    const element = node as HTMLElement;
    const style = doc.defaultView?.getComputedStyle(element);
    if (!style || style.textOverflow === "ellipsis" || style.overflow === "visible") continue;
    if (element.scrollWidth > element.clientWidth + 2 && element.clientWidth > 0 && !element.title) {
      reds.push({ rule: "layout-break", detail: `${size}: "${labelOf(node)}" is cut off` });
      break;
    }
  }
  return reds;
}

function sameLayer(a: Element, b: Element): boolean {
  // A popover, menu or dialog is drawn over the page on purpose.
  const layer = (node: Element) =>
    node.closest('[role="dialog"], [role="menu"], [role="listbox"], [popover], .ui-popover, .ui-menu');
  return layer(a) === layer(b);
}

function inScroller(node: Element): boolean {
  for (let parent = node.parentElement; parent; parent = parent.parentElement) {
    const style = node.ownerDocument.defaultView?.getComputedStyle(parent);
    if (style && /(auto|scroll|hidden)/.test(style.overflowX)) return true;
  }
  return false;
}

const area = (box: DOMRect) => Math.max(0, box.width) * Math.max(0, box.height);
function intersection(a: DOMRect, b: DOMRect): number {
  const width = Math.min(a.right, b.right) - Math.max(a.left, b.left);
  const height = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
  return width > 0 && height > 0 ? width * height : 0;
}

/// Console messages that are the page's own failures (never the dev server's or the browser's chatter).
const CONSOLE_NOISE = [/\[vite\]/i, /Download the React DevTools/i, /favicon\.ico/i, /\[HMR\]/i];
export function consoleErrors(messages: readonly string[]): Red[] {
  return messages
    .filter((message) => !CONSOLE_NOISE.some((noise) => noise.test(message)))
    .map((message) => ({ rule: "console-error" as const, detail: message.slice(0, 200) }));
}

/// Whether a person sees `node` now: inside the window and not scrolled out of a clipping list or
/// covered (the point at its middle hits it, or something inside or around it).
export function onScreen(node: Element): boolean {
  if (isJsdom(node)) return true;
  const box = node.getBoundingClientRect();
  const view = node.ownerDocument.defaultView;
  if (!view) return true;
  const x = Math.min(Math.max(box.left + box.width / 2, 0), view.innerWidth - 1);
  const y = Math.min(Math.max(box.top + Math.min(box.height / 2, 10), 0), view.innerHeight - 1);
  if (box.bottom < 0 || box.top > view.innerHeight || box.right < 0 || box.left > view.innerWidth) return false;
  const hit = node.ownerDocument.elementFromPoint(x, y);
  return !!hit && (node.contains(hit) || hit.contains(node));
}

/// Whether `node` is already the chosen one of its group: selected, pressed, current or checked.
export function isSelected(node: Element): boolean {
  for (const name of ["aria-selected", "aria-pressed", "aria-current", "aria-checked"]) {
    const value = node.getAttribute(name);
    if (value && value !== "false") return true;
  }
  return /(?:^|\s|-)(?:selected|active|current|is-selected|is-active)(?:$|\s)/.test(
    typeof node.className === "string" ? node.className : "",
  );
}

/// Whether a person can see `node`: it has a size, and nothing hides it.
export function shown(node: Element): boolean {
  const element = node as HTMLElement;
  if (element.closest?.('[hidden], [aria-hidden="true"], [inert]')) return false;
  const style = node.ownerDocument.defaultView?.getComputedStyle(element);
  if (style && (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0)) return false;
  const box = element.getBoundingClientRect?.();
  // jsdom lays nothing out: a node it cannot measure counts as shown.
  if (!box || (box.width === 0 && box.height === 0 && box.x === 0 && box.y === 0 && !element.offsetParent))
    return box !== undefined && isJsdom(node);
  return box.width > 0 && box.height > 0;
}

function isJsdom(node: Element): boolean {
  return /jsdom/i.test(node.ownerDocument.defaultView?.navigator?.userAgent ?? "");
}

/// A control's name as a person reads it.
export function labelOf(node: Element): string {
  return (
    node.getAttribute("aria-label") ||
    // A switch named by its row's title (Settings' editors): the name a screen reader says.
    (node.getAttribute("aria-labelledby") ?? "")
      .split(/\s+/)
      .map((id) => (id ? node.ownerDocument.getElementById(id)?.textContent?.replace(/\s+/g, " ").trim() : ""))
      .filter(Boolean)
      .join(" ") ||
    node.getAttribute("title") ||
    (node.textContent ?? "").replace(/\s+/g, " ").trim() ||
    describe(node)
  ).slice(0, 60);
}

function describe(node: Element): string {
  const classes = typeof node.className === "string" ? node.className.split(/\s+/).filter(Boolean).slice(0, 2) : [];
  return [node.tagName.toLowerCase(), ...classes].join(".");
}
