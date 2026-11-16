// l10n-allow-file: English patterns the measurement reads in rendered text, never shown.
//
// How a Cloud state the agent pane draws reads to the person (Leo, 2026-11-09: "especially cloud stuff, and
// getting that reliable and ergonomic. Like, the ergonomic part is super big for us."). An error either says
// what to do next with a click in the pane, points somewhere outside the pane, or is a dead end. A wait either
// says what it waits on and about how long, or reads as a bare Thinking. measure.tsx renders each state of
// states.tsx and reads it with these.

/// What a click did, as the harness saw it: in the pane (a retry, a sign-in that goes on by itself, a picker),
/// out of the pane (a browser page, a terminal, Settings, billing), or the card went away (Not now).
export type Effect = { kind: "in-place" | "out-of-app" | "dismiss"; what: string };

/// A control's way out: `inert` is a click that did nothing the harness could see (a disclosure, Copy).
export type ControlWay = "in-place" | "out-of-app" | "dismiss" | "inert";

export type ErrorClass = "next-step" | "out-of-app" | "dead-end";

/// The controls a person can click in REGIONS: enabled buttons and links, never one under Details (the raw
/// error and its Copy), hidden, inert, or a disclosure (`aria-expanded`), which only shows more of the same card.
export const CONTROL = 'button, a[href], [role="button"], input[type="button"], input[type="submit"]';
export function controlsIn(regions: readonly Element[]): Element[] {
  const found = new Set<Element>();
  for (const region of regions) {
    if (region.matches(CONTROL)) found.add(region);
    for (const node of region.querySelectorAll(CONTROL)) found.add(node);
  }
  return [...found].filter(
    (node) =>
      !node.closest("details") &&
      !node.closest('[aria-hidden="true"], [inert]') &&
      !(node as HTMLButtonElement).disabled &&
      node.getAttribute("aria-disabled") !== "true" &&
      !node.hasAttribute("aria-expanded"),
  );
}

/// A link to a web page leaves the app without a click to tell: its href says so.
export function externalHref(node: Element): string | undefined {
  const href = node.tagName === "A" ? node.getAttribute("href") : null;
  return href && /^https?:\/\//i.test(href) ? href : undefined;
}

/// One click's way: any in-pane effect wins (a Connect that opens GitHub and then retries by itself goes on in
/// the pane), then an effect outside it, then Not now. A click with no effect that changed the card (Use an API
/// key opens its field) went on in the pane too.
export function controlWay(effects: readonly Effect[], changed: boolean): ControlWay {
  if (effects.some((effect) => effect.kind === "in-place")) return "in-place";
  if (effects.some((effect) => effect.kind === "out-of-app")) return "out-of-app";
  if (effects.some((effect) => effect.kind === "dismiss")) return "dismiss";
  return changed ? "in-place" : "inert";
}

/// What a person reads in NODE: no raw error under Details, nothing hidden from them, no person's own message.
export function visibleText(node: Element, drop: readonly string[] = []): string {
  const copy = node.cloneNode(true) as Element;
  const selector = ["details", '[aria-hidden="true"]', ".visually-hidden", "script", "style", ".cv-user", ...drop].join(
    ", ",
  );
  for (const hidden of copy.querySelectorAll(selector)) hidden.remove();
  // Each text node as its own word run: elements side by side read as separate words, not run together.
  const words: string[] = [];
  const walker = copy.ownerDocument.createTreeWalker(copy, 4 /* NodeFilter.SHOW_TEXT */);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) words.push(node.nodeValue ?? "");
  return words.join(" ").replace(/\s+/g, " ").trim();
}

/// Words that send the person outside the pane to go on: a command to type (in backticks, or `cmux …`), a
/// terminal, a browser, Settings, the command palette.
const OUT_OF_APP_WORDS: readonly RegExp[] = [
  /`[^`]{2,}`/,
  /\bcmux [a-z][a-z-]+/,
  /\b(?:terminal|browser)\b/i,
  /\b(?:System )?Settings\b/,
  /\bcommand palette\b/i,
];
export function outOfAppWords(regions: readonly Element[]): string | undefined {
  for (const region of regions) {
    const code = [...region.querySelectorAll("code, kbd")].find((node) => !node.closest("details"));
    if (code) return code.textContent ?? "";
    const text = visibleText(region);
    for (const words of OUT_OF_APP_WORDS) {
      const hit = words.exec(text);
      if (hit) return hit[0];
    }
  }
  return undefined;
}

/// An error's class from its controls' ways (and an automatic recovery the pane starts by itself, as a rejected
/// Cloud credential's transfer does), then its words.
export function classifyError(ways: readonly ControlWay[], automatic: boolean, pointsOut: boolean): ErrorClass {
  if (automatic || ways.includes("in-place")) return "next-step";
  if (pointsOut || ways.includes("out-of-app")) return "out-of-app";
  return "dead-end";
}

/// An ETA is an element the wait marks as one: `data-wait-eta`, or a class that names it (`…__eta`, `…__eta-line`).
const ETA_CLASS = /(?:^|__|-)eta(?:$|-|__)/;
export function etaIn(regions: readonly Element[]): string | undefined {
  for (const region of regions)
    for (const node of [region, ...region.querySelectorAll("[data-wait-eta], [class]")]) {
      const marked = node.hasAttribute("data-wait-eta") || [...node.classList].some((name) => ETA_CLASS.test(name));
      const text = marked ? visibleText(node) : "";
      if (text) return text;
    }
  return undefined;
}

/// The words a wait shows besides its clock, tokens and ETA. Bare Thinking (any of its verbs) is no reason.
const CLOCK = /(?:\d+(?:[.,]\d+)?\s*(?:ms|s|m|h|min|sec)\b\s*)+/gi;
export function waitWords(regions: readonly Element[]): string {
  return regions
    .map((region) =>
      visibleText(region, ["time", ".cv-worked__time", ".cv-worked__sep", ".cv-worked__count", "[data-wait-eta]"]),
    )
    .join(" ")
    .replace(CLOCK, " ")
    .replace(/[.…·]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function waitReason(regions: readonly Element[], generic: ReadonlySet<string>): string | undefined {
  // An ETA element's own words are not the reason (they may sit inside the live line).
  const words = waitWords(regions.map((region) => withoutEta(region)));
  return words && !generic.has(words.toLowerCase()) ? words : undefined;
}

function withoutEta(region: Element): Element {
  const copy = region.cloneNode(true) as Element;
  for (const node of copy.querySelectorAll("[class]"))
    if ([...node.classList].some((name) => ETA_CLASS.test(name))) node.remove();
  return copy;
}
