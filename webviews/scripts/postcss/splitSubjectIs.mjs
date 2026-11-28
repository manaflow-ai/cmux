// SUBJECT-IS: a selector whose subject (its rightmost compound) starts with `:is(A, B, ...)` is written as one
// selector per argument: `.row :is(.a, .b):hover` ships as `.row .a:hover, .row .b:hover`.
//
// A style engine files each rule under its subject's class, id or tag, and on a restyle checks an element against
// only the rules filed under that element's classes, plus every rule it could not file. Blink files a subject that
// is an `:is(...)` nowhere, so each such rule is matched against every element of every restyle. In the agent pane
// 227 of them (with the `*` and bare-pseudo subjects, 389 of 2552 selectors) took 82.5% of the selector matching
// in a 60 s replay under 4x load (bench replay-under-load, trace category disabled-by-default-blink.debug
// SelectorStats); every one was matched against all 8208 elements restyled, and matched almost none.
//
// The split keeps the cascade: it is done only when every argument is a plain compound (classes, ids, attributes,
// a tag, non-functional pseudo-classes from a known list, no combinator) and all arguments have the same
// specificity, so each new selector has the old one's specificity (`:is` takes its arguments' highest), matches the
// same elements, and the rule stays where it was. `:where(...)` is left alone (its zero specificity would change),
// as are nested rules, `&`, comments, and any argument the forgiving `:is` might have been forgiving (a vendor or
// unknown pseudo would now drop the whole list).
//
// Detector: test/split-subject-is.test.ts runs every stylesheet under src/ through the build's postcss plugins and
// Lightning CSS and fails on a shipped selector this would split. Pattern: cmuxterm-hq
// docs/handbook/pane-level-has-restyles-every-row.md (the sibling HAS-LIST split, scripts/postcss/splitHasLists.mjs).

const SAFE_PSEUDOS = new Set([
  "hover",
  "active",
  "focus",
  "focus-visible",
  "focus-within",
  "disabled",
  "enabled",
  "checked",
  "empty",
  "first-child",
  "last-child",
  "only-child",
  "first-of-type",
  "last-of-type",
  "root",
  "link",
  "visited",
  "placeholder-shown",
  "read-only",
  "invalid",
  "open",
]);

/** `text` cut at each top-level `sep` (outside parens, brackets and strings). */
export function splitTop(text, sep = ",") {
  const parts = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (quote) {
      if (c === "\\") i += 1;
      else if (c === quote) quote = "";
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "\\") i += 1;
    else if (c === "(" || c === "[") depth += 1;
    else if (c === ")" || c === "]") depth -= 1;
    else if (depth === 0 && c === sep) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts.map((part) => part.trim());
}

/** Where `selector`'s subject compound starts: after its last top-level combinator. */
export function subjectStart(selector) {
  let depth = 0;
  let quote = "";
  let cut = 0;
  for (let i = 0; i < selector.length; i += 1) {
    const c = selector[i];
    if (quote) {
      if (c === "\\") i += 1;
      else if (c === quote) quote = "";
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "\\") i += 1;
    else if (c === "(" || c === "[") depth += 1;
    else if (c === ")" || c === "]") depth -= 1;
    else if (depth === 0 && (c === " " || c === ">" || c === "+" || c === "~" || c === "\n" || c === "\t")) cut = i + 1;
  }
  while (cut < selector.length && /\s/.test(selector[cut])) cut += 1;
  return cut;
}

/** The specificity of a plain compound as "ids,classes,tags", or undefined when `compound` is not plain. */
export function plainSpecificity(compound) {
  if (!compound || /[>+~&(),]|\/\*|::|\\/.test(compound) || /\s/.test(compound.replace(/\[[^\]]*\]/g, "")))
    return undefined;
  let ids = 0;
  let classes = 0;
  let tags = 0;
  let i = 0;
  const ident = /^-?[_a-zA-Z][-_a-zA-Z0-9]*/;
  if (compound[0] === "*") i = 1;
  else {
    const tag = ident.exec(compound);
    if (tag) {
      tags += 1;
      i = tag[0].length;
    }
  }
  while (i < compound.length) {
    const c = compound[i];
    if (c === "[") {
      // `[name]`, `[name=value]` or `[name="value"]` (any of `~|^$*` before the `=`), the value without a
      // space, quote, bracket or backslash in it.
      const attr =
        /^\[[-_a-zA-Z][-_a-zA-Z0-9]*(?:[~|^$*]?=(?:"[^"\s\]\\]*"|'[^'\s\]\\]*'|[-_a-zA-Z0-9]+)(?:\s+[is])?)?\]/.exec(
          compound.slice(i),
        );
      if (!attr) return undefined;
      classes += 1;
      i += attr[0].length;
      continue;
    }
    const name = ident.exec(compound.slice(i + 1));
    if (!name || (c !== "." && c !== "#" && c !== ":")) return undefined;
    if (c === "#") ids += 1;
    else if (c === ".") classes += 1;
    else if (SAFE_PSEUDOS.has(name[0])) classes += 1;
    else return undefined;
    i += 1 + name[0].length;
  }
  return `${ids},${classes},${tags}`;
}

/** The selectors `selector` splits into, or undefined to leave it as it is. */
export function splitSubject(selector) {
  if (selector.includes("&") || selector.includes("/*")) return undefined;
  const start = subjectStart(selector);
  const subject = selector.slice(start);
  if (!subject.startsWith(":is(")) return undefined;
  let depth = 0;
  let close = -1;
  for (let i = 3; i < subject.length; i += 1) {
    if (subject[i] === "(") depth += 1;
    else if (subject[i] === ")" && --depth === 0) {
      close = i;
      break;
    }
  }
  if (close < 0) return undefined;
  const args = splitTop(subject.slice(4, close));
  const rest = subject.slice(close + 1);
  if (args.length < 2 || /^[-_a-zA-Z*]/.test(rest)) return undefined;
  const specs = args.map(plainSpecificity);
  if (specs.some((spec) => spec === undefined || spec !== specs[0])) return undefined;
  const prefix = selector.slice(0, start);
  return args.map((arg) => `${prefix}${arg}${rest}`);
}

/** The selector list of `rule` with every splittable selector split, or undefined to leave it as it is. */
export function subjectIsParts(rule) {
  if (rule.parent?.type === "rule" || rule.nodes?.some((node) => node.type === "rule" || node.type === "atrule")) {
    return undefined;
  }
  let changed = false;
  const out = [];
  for (const selector of rule.selectors) {
    const parts = splitSubject(selector);
    if (parts) changed = true;
    out.push(...(parts ?? [selector]));
  }
  return changed ? out : undefined;
}

export default function splitSubjectIs() {
  return {
    postcssPlugin: "cmux-split-subject-is",
    // Before splitHasLists' pass (listed after this one), so a list this makes that holds a `:has` is split too.
    OnceExit(root) {
      root.walkRules((rule) => {
        const parts = subjectIsParts(rule);
        if (parts) rule.selectors = parts;
      });
    },
  };
}
splitSubjectIs.postcss = true;
