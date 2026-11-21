/**
 * Theme slot ratchet (schemas/theme/slots.json, src/slots/): every variant of every slot keeps the
 * slot budget, so a theme pack's variant (or ours) can never make the chat slower or move its layout.
 *
 * For each slot in slots.json:
 *   schema     the entry has docs, props, a box (block and inline), a motion spec whose durations and
 *              easings are tokens, a reduced-motion behavior and a stop condition, and its default is
 *              one of its variants, each of whose `source` and `styles` files exists.
 * For each variant's stylesheets (`styles`):
 *   raw-duration    an animation or transition duration or delay written as a `ms`/`s` literal, or a
 *                   custom property holding one, instead of a duration token.
 *   easing          `ease*` or `cubic-bezier()` instead of an easing token, `linear` or `steps()`.
 *   unknown-token   a `--cmux-*` var in motion that is not a duration or easing token.
 *   layout-property a keyframe, transition or `will-change` naming anything but transform and opacity
 *                   (`all` included): those run on the compositor; the rest lay out or paint per frame.
 *   ungated         an animation or transition outside `@media (prefers-reduced-motion: no-preference)`
 *                   or not under the slot's motion gate, so Reduce Motion and static status indicators
 *                   would still see it move.
 * For each variant's script (`source`):
 *   js-per-frame    a frame loop or timer (`requestAnimationFrame`, `setInterval`, `setTimeout`,
 *                   `requestIdleCallback`, Web Animations `.animate(`, the page clock): motion is CSS.
 *
 *   bun scripts/check-theme-slots.ts          (from webviews/; exits 1 with a line per problem)
 */
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.join(webviews, "..");
export const SCHEMA_PATH = path.join(repo, "schemas/theme/slots.json");

export type SlotsSchema = {
  tokens: { durations: string[]; easings: string[]; easingKeywords: string[] };
  budget: { animatedProperties: string[] };
  motionGate: string;
  slots: Array<{
    id: string;
    docs?: string;
    props?: Record<string, unknown>;
    box?: { block?: string; inline?: string };
    motion?: {
      durations?: Record<string, string>;
      easings?: Record<string, string>;
      reducedMotion?: string;
      stop?: string;
    };
    defaultVariant?: string;
    variants?: Array<{ id: string; source?: string; styles?: string[] }>;
  }>;
};

export type Problem = { file: string; line: number; kind: string; detail: string };

type Declaration = {
  property: string;
  value: string;
  line: number;
  selector: string;
  media: string[];
  keyframes: boolean;
};

function lineAt(text: string, index: number): number {
  let line = 1;
  for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

/** Comments blanked out with spaces, so indexes and line numbers hold. */
function withoutComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
}

/** Every declaration with its rule's selector, the @media preludes around it and whether it is in @keyframes. */
export function declarations(cssText: string): Declaration[] {
  const css = withoutComments(cssText);
  const out: Declaration[] = [];
  const stack: string[] = [];
  let start = 0;
  for (let i = 0; i < css.length; i++) {
    const ch = css[i];
    if (ch === "{") {
      stack.push(css.slice(start, i).trim().replace(/\s+/g, " "));
      start = i + 1;
    } else if (ch === "}" || ch === ";") {
      const text = css.slice(start, i);
      const colon = text.indexOf(":");
      const preludes = stack.filter(Boolean);
      const rule = preludes.at(-1) ?? "";
      if (colon > 0 && rule && !rule.startsWith("@")) {
        const property = text.slice(0, colon).trim().toLowerCase();
        if (/^[-a-z]+$/.test(property)) {
          const offset = start + text.length - text.trimStart().length;
          out.push({
            property,
            value: text.slice(colon + 1).trim(),
            line: lineAt(css, offset),
            selector: rule,
            media: preludes.filter((prelude) => prelude.startsWith("@media")),
            keyframes: preludes.some((prelude) => /^@(-webkit-)?keyframes\b/.test(prelude)),
          });
        }
      }
      if (ch === "}") stack.pop();
      start = i + 1;
    }
  }
  return out;
}

/** `value` with each var(...) and calc(...) argument list kept, split on top-level commas. */
function topLevelParts(value: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let from = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++;
    else if (value[i] === ")") depth--;
    else if (value[i] === "," && depth === 0) {
      parts.push(value.slice(from, i).trim());
      from = i + 1;
    }
  }
  parts.push(value.slice(from).trim());
  return parts.filter(Boolean);
}

const MOTION_PROPERTY =
  /^(?:animation|transition)(?:-(?:duration|delay|timing-function|name|property|iteration-count|direction|fill-mode|play-state))?$/;
const TIME_LITERAL = /(?<![-\w.])(\d*\.?\d+)(ms|s)\b/g;
const EASE_KEYWORD = /(?<![-\w])(?:ease|ease-in|ease-out|ease-in-out|cubic-bezier)(?![-\w])/;
const CSS_WIDE = new Set(["none", "initial", "inherit", "unset", "revert"]);

function rawTimes(value: string): string[] {
  return [...value.matchAll(TIME_LITERAL)].filter((match) => Number(match[1]) !== 0).map((match) => match[0]);
}

function normalizeSelector(selector: string): string {
  return selector
    .replace(/\s+/g, " ")
    .replace(/\s*,\s*/g, ", ")
    .trim();
}

/** The problems with one variant stylesheet. */
export function checkVariantCss(file: string, css: string, schema: SlotsSchema): Problem[] {
  const problems: Problem[] = [];
  const add = (line: number, kind: string, detail: string) => problems.push({ file, line, kind, detail });
  const tokens = new Set([...schema.tokens.durations, ...schema.tokens.easings]);
  const animated = new Set(schema.budget.animatedProperties);
  const gate = normalizeSelector(schema.motionGate);
  for (const decl of declarations(css)) {
    if (decl.keyframes) {
      if (!animated.has(decl.property))
        add(
          decl.line,
          "layout-property",
          `@keyframes sets ${decl.property}; only ${[...animated].join(" and ")} run on the compositor`,
        );
      continue;
    }
    if (decl.property.startsWith("--")) {
      for (const time of rawTimes(decl.value))
        add(decl.line, "raw-duration", `${decl.property} holds ${time}; use a duration token`);
      continue;
    }
    if (decl.property === "will-change") {
      for (const name of topLevelParts(decl.value))
        if (!animated.has(name) && name !== "auto") add(decl.line, "layout-property", `will-change: ${name}`);
      continue;
    }
    if (!MOTION_PROPERTY.test(decl.property)) continue;
    const value = decl.value.trim();
    if (CSS_WIDE.has(value)) continue;
    for (const time of rawTimes(value))
      add(decl.line, "raw-duration", `${decl.property}: ${time}; use a duration token`);
    if (EASE_KEYWORD.test(value))
      add(decl.line, "easing", `${decl.property}: ${value}; use an easing token, linear or steps()`);
    for (const match of value.matchAll(/var\(\s*(--[\w-]+)/g)) {
      const name = match[1]!;
      if (name.startsWith("--cmux-") && !tokens.has(name))
        add(decl.line, "unknown-token", `${name} is not a duration or easing token in slots.json`);
    }
    if (decl.property === "transition" || decl.property === "transition-property") {
      for (const part of topLevelParts(value)) {
        const name = part.split(/\s+/)[0]!;
        if (!animated.has(name)) add(decl.line, "layout-property", `transitions ${name}; only transform and opacity`);
      }
    }
    if (decl.property === "animation" || decl.property === "animation-name" || decl.property === "transition") {
      const reduced = decl.media.some((media) => /prefers-reduced-motion\s*:\s*no-preference/.test(media));
      const gated = topLevelParts(decl.selector).every((selector) => normalizeSelector(selector).startsWith(gate));
      if (!reduced || !gated)
        add(
          decl.line,
          "ungated",
          `${decl.selector}: put ${decl.property} inside @media (prefers-reduced-motion: no-preference) under ${schema.motionGate}`,
        );
    }
  }
  return problems;
}

const FRAME_LOOPS =
  /\b(requestAnimationFrame|setInterval|setTimeout|requestIdleCallback|usePageNow|useTicking)\b|\.animate\(|ui\/pageClock/g;

/** The problems with one variant script: no frame loop or timer of its own. */
export function checkVariantScript(file: string, source: string): Problem[] {
  const code = source.replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, " ")).replace(/\/\/[^\n]*/g, "");
  return [...code.matchAll(FRAME_LOOPS)].map((match) => ({
    file,
    line: lineAt(code, match.index ?? 0),
    kind: "js-per-frame",
    detail: `${match[0]}: a variant animates in CSS only (no frame loop or timer)`,
  }));
}

/** The problems with the schema itself and, read from disk under `root`, every variant's files. */
export function checkSlots(
  schema: SlotsSchema,
  root = repo,
  read = (file: string) => readFileSync(file, "utf8"),
): Problem[] {
  const problems: Problem[] = [];
  const at = path.relative(repo, SCHEMA_PATH);
  const add = (kind: string, detail: string) => problems.push({ file: at, line: 0, kind, detail });
  const durations = new Set(schema.tokens.durations);
  const easings = new Set(schema.tokens.easings);
  const keywords = new Set(schema.tokens.easingKeywords);
  const ids = new Set<string>();
  for (const slot of schema.slots) {
    if (ids.has(slot.id)) add("schema", `${slot.id}: duplicate slot id`);
    ids.add(slot.id);
    if (!slot.docs?.trim()) add("schema", `${slot.id}: no docs`);
    if (!slot.props || Object.keys(slot.props).length === 0) add("schema", `${slot.id}: no props contract`);
    if (!slot.box?.block?.trim() || !slot.box.inline?.trim())
      add("schema", `${slot.id}: the box needs block and inline`);
    const motion = slot.motion;
    if (!motion?.reducedMotion?.trim()) add("schema", `${slot.id}: the motion spec needs its reduced-motion behavior`);
    if (!motion?.stop?.trim()) add("schema", `${slot.id}: the motion spec needs its stop condition`);
    for (const [role, token] of Object.entries(motion?.durations ?? {}))
      if (!durations.has(token))
        add("raw-duration", `${slot.id}: motion.durations.${role} is ${token}, not a duration token`);
    for (const [role, token] of Object.entries(motion?.easings ?? {}))
      if (!easings.has(token) && !keywords.has(token))
        add("easing", `${slot.id}: motion.easings.${role} is ${token}, not an easing token`);
    const variants = slot.variants ?? [];
    if (!variants.some((variant) => variant.id === slot.defaultVariant))
      add("schema", `${slot.id}: the default ${slot.defaultVariant} is not one of its variants`);
    for (const variant of variants) {
      const files = [variant.source, ...(variant.styles ?? [])].filter((file): file is string => Boolean(file));
      if (!variant.source) add("schema", `${slot.id}/${variant.id}: no source`);
      for (const file of files) {
        const full = path.join(root, file);
        if (!existsSync(full)) {
          add("schema", `${slot.id}/${variant.id}: ${file} does not exist`);
          continue;
        }
        const text = read(full);
        problems.push(
          ...(file.endsWith(".css") ? checkVariantCss(file, text, schema) : checkVariantScript(file, text)),
        );
      }
    }
  }
  return problems;
}

if (import.meta.main) {
  const schema = JSON.parse(readFileSync(SCHEMA_PATH, "utf8")) as SlotsSchema;
  // A stylesheet several variants share is read once per variant: report each problem once.
  const seen = new Set<string>();
  const problems = checkSlots(schema).filter((problem) => {
    const key = `${problem.file}:${problem.line}:${problem.detail}`;
    return seen.has(key) ? false : (seen.add(key), true);
  });
  for (const problem of problems) console.error(`${problem.file}:${problem.line}: ${problem.kind}: ${problem.detail}`);
  if (problems.length) {
    console.error(`check:theme-slots: ${problems.length} problem(s); the slot budget is in schemas/theme/slots.json`);
    process.exit(1);
  }
  console.log(`check:theme-slots: ${schema.slots.length} slot(s) keep the budget`);
}
