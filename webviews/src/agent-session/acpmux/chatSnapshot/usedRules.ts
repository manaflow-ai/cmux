// The page's sheets beside its main one, cut to what a copy can use. They hold every chunk's rules
// (the markdown and diff viewers' inlined CSS, a chat font's face as a data URL): about 480k
// characters on a real chat, more than the whole copy may take (shared.ts SNAPSHOT_MAX_CHARS), so a
// copy that carried them whole was never kept. A rule stays when every class and id its selectors
// need is on some element of the copy, or on `<html>` or `<body>`; a face or keyframes stays when
// what is kept names it. A superset of the rules that match, found in one pass over the copy and one
// over the rules, with no selector matching.

/// The class names and ids the copy's elements (and the document's root and body) carry.
export type UsedNames = { classes: Set<string>; ids: Set<string> };

export function usedNames(elements: Iterable<Element>): UsedNames {
  const classes = new Set<string>();
  const ids = new Set<string>();
  for (const element of elements) {
    for (const name of Array.from(element.classList)) classes.add(name);
    if (element.id) ids.add(element.id);
  }
  return { classes, ids };
}

/// The selector without what a match does not need present: the arguments of `:not()`, `:has()`,
/// `:is()`, `:where()` and other functional pseudo-classes (any of them may name what is absent),
/// and attribute selectors (whose values may hold a `.` or `#`).
function required(selector: string): string {
  let out = "";
  let depth = 0;
  for (const char of selector) {
    if (char === "(" || char === "[") depth += 1;
    if (depth === 0) out += char;
    if (char === ")" || char === "]") depth = Math.max(0, depth - 1);
  }
  return out;
}

const NAME = /([.#])((?:\\.|[\w-])+)/g;

/// Whether one complex selector can match in the copy: each class and id it needs is in `used`.
function selectorFits(selector: string, used: UsedNames): boolean {
  for (const match of required(selector).matchAll(NAME)) {
    const name = match[2]!.replace(/\\(.)/g, "$1");
    if (match[1] === "." ? !used.classes.has(name) : !used.ids.has(name)) return false;
  }
  return true;
}

/// Splits a selector list at its top-level commas.
function selectorList(text: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let at = 0; at < text.length; at += 1) {
    const char = text[at];
    if (char === "(" || char === "[") depth += 1;
    else if (char === ")" || char === "]") depth -= 1;
    else if (char === "," && depth === 0) {
      parts.push(text.slice(start, at));
      start = at + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

type Deferred = { name: string; text: string };

/// Kept rules' text, and the faces and keyframes left to decide once all kept text is known.
function keep(rules: CSSRuleList, used: UsedNames, faces: Deferred[], frames: Deferred[]): string[] {
  const kept: string[] = [];
  for (const rule of Array.from(rules)) {
    const style = rule as CSSStyleRule;
    if (typeof style.selectorText === "string") {
      if (selectorList(style.selectorText).some((selector) => selectorFits(selector, used))) kept.push(rule.cssText);
      continue;
    }
    const group = rule as CSSGroupingRule;
    const face = rule.constructor?.name === "CSSFontFaceRule" || rule.cssText.startsWith("@font-face");
    if (face) {
      const family = (rule as CSSFontFaceRule).style?.getPropertyValue("font-family") ?? "";
      faces.push({ name: family.replace(/^["']|["']$/g, "").trim(), text: rule.cssText });
      continue;
    }
    const keyframes = rule as CSSKeyframesRule;
    if (typeof keyframes.name === "string" && rule.cssText.startsWith("@")) {
      if (/^@(-webkit-)?keyframes/.test(rule.cssText)) {
        frames.push({ name: keyframes.name, text: rule.cssText });
        continue;
      }
    }
    if (group.cssRules && "insertRule" in group) {
      // @media, @supports, @container, @layer blocks: kept with what they hold that is kept.
      const inner = keep(group.cssRules, used, faces, frames);
      if (inner.length === 0) continue;
      const head = rule.cssText.slice(0, rule.cssText.indexOf("{"));
      kept.push(`${head}{\n${inner.join("\n")}\n}`);
      continue;
    }
    // @property, @layer and @namespace statements and the like: small, kept.
    kept.push(rule.cssText);
  }
  return kept;
}

/// `sheet` cut to what a copy of `used` can use, as text; empty when nothing is.
/// `alsoNamed` is other text that may name a face or keyframes (the copy's inline styles, the
/// root's variables).
export function usedRules(sheet: CSSStyleSheet, used: UsedNames, alsoNamed: string): string {
  let rules: CSSRuleList;
  try {
    rules = sheet.cssRules;
  } catch {
    return "";
  }
  const faces: Deferred[] = [];
  const frames: Deferred[] = [];
  const kept = keep(rules, used, faces, frames);
  const named = `${kept.join("\n")}\n${alsoNamed}`;
  const extra = [...faces, ...frames].filter((item) => item.name && named.includes(item.name));
  return [...extra.map((item) => item.text), ...kept].join("\n");
}
