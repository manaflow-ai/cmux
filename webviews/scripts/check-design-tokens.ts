/**
 * Design-token ratchet for first-party webview surfaces.
 *
 * New literal spacing and control sizes must use the adopted scale. Existing debt is recorded in
 * design-tokens-baseline.jsonl; the baseline can only shrink with --update-baseline. Glass fills use
 * the same resolver as check-glass-never-opaque, with named floating surfaces included even while
 * their markup is being migrated to `.ui-glass`.
 *
 * Token literals (design/grid.md, tokens.md, motion-scale.json), in CSS and in TSX inline `style={{}}`
 * objects, outside the token files (pages/shared/desktop.css, generated CSS) and outside custom
 * property definitions (`--x: ...` is a token definition):
 *   color        a raw #hex, rgb()/rgba()/hsl()/hsla()/hwb()/lab()/lch()/oklab()/oklch()/color() literal
 *                that is not a var() fallback and takes no var() argument.
 *   spacing      padding/gap (as before), margin and inset/top/right/bottom/left off 0/4/8/12/16/24/32/40/48/56.
 *   radius       border-radius off 0/4/6/8/12/16 (menu 5 comes from --cmux-menu-*; >= 999px is a capsule).
 *   font-weight  anything but 400/600 (`normal`); 700 for monograms is recorded in the baseline.
 *   duration     a literal transition/animation duration other than 0, not var(--cmux-motion-*).
 *   easing       cubic-bezier() or ease/ease-in/ease-out/ease-in-out, not var(--cmux-ease-out).
 *   transition-all  `transition: all ...` or `transition-property: all`: it animates whatever property
 *                changes next, layout ones included, so a later width or position change starts to move
 *                with no one deciding it should. Name the properties (opacity, transform, a colour).
 *                None today, so no baseline row holds one.
 *   motion-literal  a TS/TSX file (tests and galleries too) typing a motion-scale step or curve instead of
 *                importing it from motion/scale.generated.ts (see scriptMotionFindings).
 * Font sizes are the type-scale ratchet's job (scripts/cmux-next/check-type-scale.py), not this one's.
 * A migration PR shrinks the baseline with `bun scripts/check-design-tokens.ts --update-baseline`,
 * which refuses to grow any count.
 *
 * Token-only surfaces (TOKEN_ONLY_FILES): a visible element built from the references, the spec and
 * the tokens alone (Leo, 2026-11-10, on the unread marker: "make it look integrated and all that ...
 * don't introduce any random stuff"; cmuxterm-hq docs/handbook/feature-thrown-in-without-design.md).
 * Such a file has no baseline, and it is stricter than the ratchet: a literal colour, duration or
 * easing is refused even as a var() fallback or in a custom property, a radius must be a token, and
 * a TSX file holds no colour literal at all. A new visible element adds its sheet and component here.
 */
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";
import { fillKind, glassContextRules, targetsRequiredGlass, type Block } from "./check-glass-never-opaque";
import { isIconSelector } from "./check-icon-scale";
import { normalizePxMs, propertyFamily, tokenFor, type TokenFamily } from "./design-token-values";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(ROOT, "src");
const BASELINE = join(dirname(fileURLToPath(import.meta.url)), "design-tokens-baseline.jsonl");
const SPACING = new Set([0, 4, 8, 12, 16, 24, 32]);
/** Layout gaps (design/grid.md) are on the scale for margins and positioned insets. */
const LAYOUT_SPACING = new Set([...SPACING, 40, 48, 56]);
const RADIUS = new Set([0, 4, 6, 8, 12, 16]);
const CAPSULE_RADIUS = 999;
const WEIGHTS = new Set(["400", "600", "normal"]);
/** Token definitions and generated sheets: the literals the rest of the tree must reference. */
const TOKEN_FILES = new Set(["pages/shared/desktop.css"]);
const CONTROL_HEIGHT = new Set([0, 20, 24, 28, 32]);
// An icon box's height is on the icon scale (design/grid.md: 12, 14, 16, 20), which check-icon-scale.ts owns.
const ICON_HEIGHT = new Set([...CONTROL_HEIGHT, 12, 14, 16]);
const CSS_ROOTS = ["."];
const ROOT_FILES: string[] = [];
const NAMED_GLASS = /\.(?:nt-box|acpmux-env-panel|acpmux-composer-strip|acpmux-composer)\b/;
const SPACING_PROPERTY = /^(?:padding(?:-(?:block|inline|top|right|bottom|left))?|gap|row-gap|column-gap)$/;
const HEIGHT_PROPERTY = /^(?:height|min-height)$/;
const LAYOUT_PROPERTY =
  /^(?:margin(?:-(?:block|inline|top|right|bottom|left)(?:-(?:start|end))?)?|inset(?:-(?:block|inline)(?:-(?:start|end))?)?|top|right|bottom|left)$/;
const RADIUS_PROPERTY = /^border(?:-(?:top|bottom|start|end)-(?:left|right|start|end))?-radius$/;
const DURATION_PROPERTY = /^(?:transition|animation)(?:-duration)?$/;
const EASING_PROPERTY = /^(?:transition|animation)(?:-timing-function)?$/;
const TRANSITION_PROPERTY = /^transition(?:-property)?$/;
/** `all` as one transition's property: the first word of a comma-separated item. */
const TRANSITION_ALL = /(?:^|,)\s*all(?![\w-])/i;
const COLOR_FUNCTION = /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(/gi;
/** Properties whose strings and idents are not colours (`content: "#1"`). */
const NOT_COLOR_PROPERTY =
  /^(?:(?:-webkit-)?mask(?:-[a-z-]+)?|content|quotes|grid-template-areas|font-feature-settings|font-variation-settings|counter-\w+)$/;
const HEX_COLOR = /#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})\b/i;
const REDUCE_MEDIA = /(?<!not\s*)\(\s*prefers-reduced-transparency\s*:\s*reduce\s*\)/;
const REDUCE_ATTR = /(?<!:not\(\s*)\[data-reduce-transparency\]/;

export interface Finding {
  file: string;
  kind:
    | "spacing"
    | "height"
    | "opaque-glass"
    | "color"
    | "radius"
    | "font-weight"
    | "duration"
    | "easing"
    | "transition-all"
    | "motion-literal"
    | "token-only"
    | "token-copy";
  selector: string;
  property: string;
  value: string;
  line: number;
  /** token-copy: the token that already holds the value, and its sheet under src/. */
  token?: string;
  sheet?: string;
}

/** `value` with every var(...) call replaced by `\u00a7`, so a token and its fallback are not literals. */
function withoutVars(value: string): string {
  let out = "";
  for (let i = 0; i < value.length; i++) {
    if (value.startsWith("var(", i)) {
      let depth = 0;
      for (; i < value.length; i++) {
        if (value[i] === "(") depth++;
        else if (value[i] === ")" && --depth === 0) break;
      }
      out += "\u00a7";
      continue;
    }
    out += value[i];
  }
  return out;
}

/**
 * A raw colour literal outside var(): a hex, or a colour function none of whose arguments is a
 * token (`rgb(var(--accent-rgb) / 0.5)` and `color-mix(in srgb, var(--x) 40%, transparent)` compose tokens).
 */
export function hasRawColor(value: string): boolean {
  const bare = withoutVars(value).replace(/url\([^)]*\)/gi, " ");
  if (HEX_COLOR.test(bare)) return true;
  for (const match of bare.matchAll(COLOR_FUNCTION)) {
    let depth = 1;
    let end = (match.index ?? 0) + match[0].length;
    const start = end;
    for (; end < bare.length && depth; end++) {
      if (bare[end] === "(") depth++;
      else if (bare[end] === ")") depth--;
    }
    if (!bare.slice(start, end).includes("\u00a7")) return true;
  }
  return false;
}

function outside(values: number[], allowed: Set<number>, capsule = false): boolean {
  return values.some((number) => {
    const size = Math.abs(number);
    return !allowed.has(size) && !(capsule && size >= CAPSULE_RADIUS);
  });
}

/** The token-literal kind a declaration breaks, if any (spacing/height keep their own path below). */
export function tokenLiteralKind(property: string, value: string): Finding["kind"] | undefined {
  if (property.startsWith("--")) return undefined;
  if (LAYOUT_PROPERTY.test(property) && outside(pxValues(value), LAYOUT_SPACING)) return "spacing";
  if (RADIUS_PROPERTY.test(property) && outside(pxValues(value), RADIUS, true)) return "radius";
  if (property === "font-weight") {
    const weight = value.trim().toLowerCase();
    if (!WEIGHTS.has(weight) && !/^(?:var\(|inherit|initial|unset|revert)/.test(weight)) return "font-weight";
  }
  if (TRANSITION_PROPERTY.test(property) && TRANSITION_ALL.test(withoutVars(value))) return "transition-all";
  if (DURATION_PROPERTY.test(property)) {
    const times = [...withoutVars(value).matchAll(/(?<![\w.-])(\d*\.?\d+)(ms|s)\b/gi)].map((m) => Number(m[1]));
    if (times.some((time) => time !== 0)) return "duration";
  }
  if (
    EASING_PROPERTY.test(property) &&
    /\bcubic-bezier\(|(?<![\w-])ease(?:-in|-out|-in-out)?(?![\w-])/i.test(withoutVars(value))
  )
    return "easing";
  if (!NOT_COLOR_PROPERTY.test(property) && hasRawColor(value)) return "color";
  return undefined;
}

function cssFiles(): string[] {
  const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      if (entry.isDirectory() && (entry.name === "node_modules" || entry.name === "generated")) return [];
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return walk(path);
      return entry.name.endsWith(".css") ? [path] : [];
    });
  return [...CSS_ROOTS.map((name) => walk(join(SRC, name))), ...ROOT_FILES.map((name) => join(SRC, name))].flat();
}

interface ParsedBlock {
  selector: string;
  context: string[];
  line: number;
  declarations: { property: string; value: string; line: number }[];
}

/** Small CSS scanner. It preserves selectors and at-rule context, including minified sheets. */
function parse(text: string): ParsedBlock[] {
  const blocks: ParsedBlock[] = [];
  const stack: { prelude: string; block: ParsedBlock }[] = [];
  let buf = "";
  let line = 1;
  let i = 0;
  const flush = () => {
    const raw = buf.trim();
    buf = "";
    const block = stack.at(-1)?.block;
    const colon = raw.indexOf(":");
    if (!block || colon < 1) return;
    block.declarations.push({
      property: raw.slice(0, colon).trim().toLowerCase(),
      value: raw
        .slice(colon + 1)
        .trim()
        .replace(/\s+/g, " ")
        .replace(/\s*!important$/, ""),
      line,
    });
  };
  while (i < text.length) {
    const ch = text[i];
    if (ch === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      const comment = text.slice(i, end < 0 ? text.length : end + 2);
      line += comment.split("\n").length - 1;
      i = end < 0 ? text.length : end + 2;
      continue;
    }
    if (ch === '"' || ch === "'") {
      const end = text.indexOf(ch, i + 1);
      const literal = text.slice(i, end < 0 ? text.length : end + 1);
      buf += literal;
      line += literal.split("\n").length - 1;
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (ch === "\n") line++;
    if (ch === "{") {
      const selector = buf.trim().replace(/\s+/g, " ");
      buf = "";
      const block: ParsedBlock = {
        selector,
        context: stack.map((entry) => entry.prelude),
        line,
        declarations: [],
      };
      blocks.push(block);
      stack.push({ prelude: selector, block });
    } else if (ch === "}") {
      flush();
      stack.pop();
    } else if (ch === ";") {
      flush();
    } else {
      buf += ch;
    }
    i++;
  }
  return blocks;
}

/**
 * `calc(N * var(--ui-px, 1px))` is N px at the interface scale (ui/popupSurface.css: a floating
 * surface's frame follows Text Size), so it is N on the scale, not the fallback's 1px.
 */
const UI_PX = /calc\(\s*(-?(?:\d+\.?\d*|\.\d+))\s*\*\s*var\(\s*--ui-px\s*(?:,\s*1px\s*)?\)\s*\)/gi;

function pxValues(value: string): number[] {
  const scaled = value.replace(UI_PX, "$1px");
  return [...scaled.matchAll(/(-?(?:\d+\.?\d*|\.\d+))px\b/gi)].map((match) => Number(match[1]));
}

export function isOutsideScale(property: string, value: string, selector = ""): boolean {
  const values = pxValues(value);
  // Tokens do not exempt adjacent literals or fallback values from the scale.
  if (!values.length) return false;
  const heights = isIconSelector(selector) ? ICON_HEIGHT : CONTROL_HEIGHT;
  const allowed = HEIGHT_PROPERTY.test(property) ? heights : SPACING;
  return values.some((number) => !allowed.has(number));
}

function inReduce(block: ParsedBlock): boolean {
  return [...block.context, block.selector].some((part) => REDUCE_MEDIA.test(part) || REDUCE_ATTR.test(part));
}

function key(finding: Omit<Finding, "line">): string {
  // Group by file, finding kind, property and value. Selectors are intentionally omitted so a
  // moved rule keeps its allowance, while a new off-scale value cannot hide in an old bucket.
  return [finding.file, finding.kind, finding.property, finding.value].join("\t");
}

/** Sheets and components that may use tokens only (see the header). Paths under src/. */
export const TOKEN_ONLY_FILES: readonly string[] = [
  "agent-session/acpmux/conversation/unread.css",
  "agent-session/acpmux/conversation/SinceDivider.tsx",
  "agent-session/acpmux/jumpPair.css",
  // The public kit (kit/index.ts): what customization pages, plugins and web pages compose.
  "kit/kit.css",
  "kit/Row.tsx",
  "kit/List.tsx",
  "kit/Pill.tsx",
  "kit/Avatar.tsx",
  "kit/Field.tsx",
  "kit/GlassMenu.tsx",
  "kit/PopoverButton.tsx",
  "kit/presets/SessionList.tsx",
];
const ANY_DURATION = /(?<![\w.-])\d*\.?\d+m?s\b/i;
const ANY_EASING = /\bcubic-bezier\(|\bsteps\(|\blinear\(|(?<![\w-])ease(?:-in|-out|-in-out)?(?![\w-])/i;
const TOKEN_RADIUS = /^(?:0|50%|inherit|var\(--[\w-]+\))$/;

/** What makes `value` a literal in a token-only file, var() fallbacks included. */
export function tokenOnlyKind(property: string, value: string): string | undefined {
  const bare = value.replace(/url\([^)]*\)/gi, " ");
  if (HEX_COLOR.test(bare)) return "a colour literal";
  // A colour function only around tokens (`rgb(var(--x-rgb) / 0.5)`); color-mix() of var()s is not one.
  for (const match of bare.matchAll(COLOR_FUNCTION)) {
    let depth = 1;
    let end = (match.index ?? 0) + match[0].length;
    const start = end;
    for (; end < bare.length && depth; end++) {
      if (bare[end] === "(") depth++;
      else if (bare[end] === ")") depth--;
    }
    if (!bare.slice(start, end).includes("var(")) return "a colour literal";
  }
  if (/^(?:transition|animation)/.test(property) || property.startsWith("--")) {
    if (ANY_DURATION.test(value)) return "a duration literal";
    if (ANY_EASING.test(value)) return "an easing literal";
  }
  if (RADIUS_PROPERTY.test(property) && !TOKEN_RADIUS.test(value.trim())) return "a radius that is not a token";
  return undefined;
}

/** A token-only file's findings: the ratchet's own (with no baseline) and the stricter ones. */
export function tokenOnlyFindings(rel: string, source: string): Finding[] {
  const findings: Finding[] = [];
  if (rel.endsWith(".css")) {
    for (const block of parse(source)) {
      for (const declaration of block.declarations) {
        const why = tokenOnlyKind(declaration.property, declaration.value);
        if (why)
          findings.push({
            file: rel,
            kind: "token-only",
            selector: block.selector,
            property: declaration.property,
            value: `${declaration.value} (${why})`,
            line: declaration.line,
          });
      }
    }
    return findings;
  }
  // A component: no colour literal anywhere outside comments, and its inline styles on tokens.
  const code = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, (comment) => comment.replace(/[^\n]/g, " "));
  code.split("\n").forEach((text, index) => {
    if (HEX_COLOR.test(text) || /\b(?:rgba?|hsla?|oklch|oklab)\(/i.test(text))
      findings.push({
        file: rel,
        kind: "token-only",
        selector: "",
        property: "source",
        value: `${text.trim()} (a colour literal)`,
        line: index + 1,
      });
  });
  return [...findings, ...inlineStyleFindings(rel, source)];
}

/** Every token-only file's findings; each is an error, whatever the baseline holds. */
export function findTokenOnlyViolations(): Finding[] {
  return TOKEN_ONLY_FILES.flatMap((rel) => {
    const path = join(SRC, rel);
    if (!existsSync(path))
      return [
        {
          file: rel,
          kind: "token-only" as const,
          selector: "",
          property: "file",
          value: "missing (TOKEN_ONLY_FILES names a file that is not there)",
          line: 0,
        },
      ];
    const source = readFileSync(path, "utf8");
    const ratchet = rel.endsWith(".css") ? findingsForFile(path) : [];
    return [...ratchet, ...tokenOnlyFindings(rel, source)];
  });
}

function findingsForFile(file: string): Finding[] {
  const text = readFileSync(file, "utf8");
  const rel = relative(SRC, file);
  const tokenFile = TOKEN_FILES.has(rel.replaceAll("\\", "/"));
  const blocks = parse(text);
  const findings: Finding[] = [];
  for (const block of blocks) {
    if (block.selector.startsWith("@") || inReduce(block)) continue;
    for (const declaration of block.declarations) {
      if (declaration.property.startsWith("--")) continue;
      if (SPACING_PROPERTY.test(declaration.property) && isOutsideScale(declaration.property, declaration.value)) {
        findings.push({
          file: rel,
          kind: "spacing",
          selector: block.selector,
          property: declaration.property,
          value: declaration.value,
          line: declaration.line,
        });
      } else if (
        HEIGHT_PROPERTY.test(declaration.property) &&
        isOutsideScale(declaration.property, declaration.value, block.selector)
      ) {
        findings.push({
          file: rel,
          kind: "height",
          selector: block.selector,
          property: declaration.property,
          value: declaration.value,
          line: declaration.line,
        });
      } else if (!tokenFile) {
        const kind = tokenLiteralKind(declaration.property, declaration.value);
        if (kind) {
          findings.push({
            file: rel,
            kind,
            selector: block.selector,
            property: declaration.property,
            value: declaration.value,
            line: declaration.line,
          });
        }
      }
    }
  }
  return findings;
}

function glassFindings(): Finding[] {
  const blocks = glassContextRules(SRC) as Block[];
  const findings: Finding[] = [];
  for (const block of blocks) {
    if (inReduce(block as unknown as ParsedBlock)) continue;
    const named = NAMED_GLASS.test(block.selector);
    const glass =
      named ||
      targetsRequiredGlass(block.selector) ||
      /\.[\w-]*glass[\w-]*/i.test(block.selector) ||
      block.decls.some((decl) => decl.prop.endsWith("backdrop-filter"));
    if (!glass) continue;
    for (const declaration of block.decls) {
      if (declaration.allowed) continue;
      const isFill = declaration.prop === "background" || declaration.prop === "background-color";
      const isGlassToken = declaration.prop.startsWith("--") && declaration.prop.includes("glass");
      if (!isFill && !isGlassToken) continue;
      const opaque = /^\d+(?:\.\d+)?%$/.test(declaration.value)
        ? Number.parseFloat(declaration.value) >= 100
        : fillKind(declaration.value) === "opaque";
      if (opaque) {
        findings.push({
          file: block.file,
          kind: "opaque-glass",
          selector: block.selector,
          property: declaration.prop,
          value: declaration.value,
          line: declaration.line,
        });
      }
    }
  }
  return findings;
}

function tsxFiles(): string[] {
  const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      if (entry.isDirectory() && (entry.name === "node_modules" || entry.name === "generated")) return [];
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return walk(path);
      return entry.name.endsWith(".tsx") && !entry.name.includes(".test.") ? [path] : [];
    });
  return walk(SRC);
}

/** React appends px to a bare number on these properties. */
const PX_NUMBER_PROPERTY =
  /^(?:padding|margin|gap|row-gap|column-gap|inset|top|right|bottom|left|border(?:-[a-z]+)*-radius|height|min-height)(?:-[a-z-]+)?$/;

function kebab(name: string): string {
  return name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

/** Unwrap syntax-only wrappers around a style expression. */
function unwrapExpression(node: ts.Expression): ts.Expression {
  if (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isSatisfiesExpression(node)) {
    return unwrapExpression(node.expression);
  }
  return node;
}

/** The literal values an inline style property can take: a string, a number, or either branch of ?: / ?? / ||. */
function styleValues(node: ts.Expression, property: string): string[] {
  node = unwrapExpression(node);
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return [node.text];
  if (ts.isTemplateExpression(node))
    return [node.head.text + node.templateSpans.map((span) => `var(--expr)${span.literal.text}`).join("")];
  if (ts.isNumericLiteral(node))
    return [PX_NUMBER_PROPERTY.test(property) && Number(node.text) !== 0 ? `${node.text}px` : node.text];
  if (
    ts.isPrefixUnaryExpression(node) &&
    node.operator === ts.SyntaxKind.MinusToken &&
    ts.isNumericLiteral(node.operand)
  )
    return styleValues(node.operand, property).map((value) => `-${value}`);
  if (ts.isConditionalExpression(node))
    return [...styleValues(node.whenTrue, property), ...styleValues(node.whenFalse, property)];
  if (
    ts.isBinaryExpression(node) &&
    (node.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken ||
      node.operatorToken.kind === ts.SyntaxKind.BarBarToken)
  )
    return styleValues(node.right, property);
  return [];
}

/** Literal design values in TSX inline `style={{ ... }}` objects, judged like the same CSS declaration. */
export function inlineStyleFindings(rel: string, source: string): Finding[] {
  const ast = ts.createSourceFile(rel, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const findings: Finding[] = [];
  const visit = (node: ts.Node) => {
    const styleObject =
      ts.isJsxAttribute(node) &&
      ts.isIdentifier(node.name) &&
      node.name.text === "style" &&
      node.initializer &&
      ts.isJsxExpression(node.initializer) &&
      node.initializer.expression
        ? unwrapExpression(node.initializer.expression)
        : undefined;
    if (styleObject && ts.isObjectLiteralExpression(styleObject)) {
      for (const prop of styleObject.properties) {
        if (!ts.isPropertyAssignment(prop)) continue;
        const name = ts.isIdentifier(prop.name) || ts.isStringLiteral(prop.name) ? prop.name.text : undefined;
        if (!name || name.startsWith("--")) continue;
        const property = kebab(name);
        const line = ast.getLineAndCharacterOfPosition(prop.getStart(ast)).line + 1;
        for (const value of styleValues(prop.initializer, property)) {
          const kind =
            SPACING_PROPERTY.test(property) && isOutsideScale(property, value)
              ? "spacing"
              : HEIGHT_PROPERTY.test(property)
                ? undefined
                : tokenLiteralKind(property, value);
          if (kind) findings.push({ file: rel, kind, selector: "style={{}}", property, value, line });
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function tsxFindings(): Finding[] {
  return tsxFiles().flatMap((file) => inlineStyleFindings(relative(SRC, file), readFileSync(file, "utf8")));
}

/*
 * Token copies (`token-copy`): a px/ms literal that equals a value one named token already holds, in a
 * test, a gallery, or a stylesheet declaration. The number then lives in two places, and a change to
 * the token silently leaves the copy behind (cmux#43627 moved one line height through 11 files). The
 * tokens are design-token-values.ts's: plain px/ms `:root` custom properties, global or of the file's
 * own surface, matched only within one family (radius, duration, spacing, size, stroke) and only when
 * exactly one token holds the value there, so `line-height: 18px` is never told to use an 18px radius
 * and an 8px that four tokens share is never a finding.
 *
 * Where a literal counts:
 *   CSS (every sheet, galleries included): a declaration's px/ms outside var() and calc(), judged by
 *     the property (`gap: 2px` is --grid-half-step's spacing; a custom property definition is a token).
 *   tests and galleries (`*.test.*`, `*.gallery.*` under src/ and test/): a "Npx"/"Nms" string that
 *     is an expect() argument or matcher argument, a ===/!== operand, or an inline `style={{}}` value.
 *     The property comes from the style key, the object key it sits under, or the last CSS property
 *     named in the expect() subject / the other operand (`style.gap`, `.get("gap")`,
 *     `getPropertyValue("gap")`); a string with no property hint is a finding only as a duration.
 *
 * How to read a finding: `token copy: <file>:<line> <context> "<value>" is <token> (<sheet>)`. Use the
 * token instead: var(<token>) in CSS or a style object; in a test, read it with designTokenValue from
 * test/support/gridTokens.ts (bun) or getComputedStyle(...).getPropertyValue("<token>") (browser).
 * A literal that only happens to equal a token (a fixture size, an unrelated 40px) is debt only if
 * it should follow the token; otherwise rename nothing and leave it in the baseline, which only shrinks.
 */
const LITERAL_PX_MS = /(?<![\w.#-])(-?(?:\d+\.?\d*|\.\d+))(px|ms)\b/gi;
const STROKE_SHORTHAND = /^(?:outline|border(?:-(?:top|right|bottom|left|block|inline))?)$/;

/** `value` with var() and calc() calls dropped, so fallbacks and arithmetic are not copies. */
function withoutVarsOrCalc(value: string): string {
  return withoutVars(value).replace(/calc\((?:[^()]|\([^()]*\))*\)/gi, "§");
}

function onScale(family: TokenFamily, value: string, icon: boolean): boolean {
  if (!value.endsWith("px")) return false;
  const size = Math.abs(Number.parseFloat(value));
  if (family === "spacing") return LAYOUT_SPACING.has(size);
  if (family === "radius") return RADIUS.has(size);
  if (family === "size") return (icon ? ICON_HEIGHT : CONTROL_HEIGHT).has(size);
  return false;
}

function cssTokenCopies(file: string): Finding[] {
  const rel = relative(SRC, file).replaceAll("\\", "/");
  const findings: Finding[] = [];
  for (const block of parse(readFileSync(file, "utf8"))) {
    if (block.selector.startsWith("@") || /^(?:from|to|\d+(?:\.\d+)?%)/.test(block.selector)) continue;
    const icon = isIconSelector(block.selector);
    for (const declaration of block.declarations) {
      if (declaration.property.startsWith("--")) continue;
      const family = STROKE_SHORTHAND.test(declaration.property) ? "stroke" : propertyFamily(declaration.property);
      if (!family) continue;
      for (const match of withoutVarsOrCalc(declaration.value).matchAll(LITERAL_PX_MS)) {
        const value = normalizePxMs(match[0]);
        const literalFamily = value?.endsWith("ms") ? "duration" : family;
        if (!value || (literalFamily === "duration") !== (family === "duration")) continue;
        // A stylesheet may write a value on the adopted scale as a literal (design/grid.md; the ratchet
        // above owns that scale); only an off-scale value a token names is a copy there.
        if (onScale(literalFamily, value, icon)) continue;
        const token = tokenFor(rel, value, literalFamily, block.selector, icon);
        if (token)
          findings.push({
            file: rel,
            kind: "token-copy",
            selector: block.selector,
            property: declaration.property,
            value,
            line: declaration.line,
            token: token.name,
            sheet: token.sheet,
          });
      }
    }
  }
  return findings;
}

const KNOWN_PROPERTY =
  /^(?:border(?:-[a-z]+)*-radius|transition(?:-duration|-delay)?|animation(?:-duration|-delay)?|padding(?:-[a-z-]+)?|margin(?:-[a-z-]+)?|inset(?:-[a-z-]+)?|(?:row-|column-)?gap|top|right|bottom|left|(?:min-|max-)?(?:width|height)|block-size|inline-size|flex-basis|outline(?:-width)?|border(?:-[a-z]+)?-width)$/;

/** The last CSS property a piece of code names (`style.borderRadius`, `.get("gap")`, `"min-height"`). */
function propertyHint(text: string): string | undefined {
  let hint: string | undefined;
  for (const match of text.matchAll(/[A-Za-z][\w-]*/g)) {
    const property = kebab(match[0]);
    if (KNOWN_PROPERTY.test(property)) hint = property;
  }
  return hint;
}

function testAndGalleryFiles(): string[] {
  const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      if (entry.isDirectory() && (entry.name === "node_modules" || entry.name === "generated")) return [];
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return walk(path);
      return /\.(?:test|gallery)\.tsx?$/.test(entry.name) || /\.gallery\.[\w.]*tsx?$/.test(entry.name) ? [path] : [];
    });
  return [...walk(SRC), ...walk(join(ROOT, "test"))];
}

function isExpectCall(node: ts.Node): boolean {
  return ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "expect";
}

/** The expect(...) call at the root of a matcher chain (`expect(x).not.toBe`), if `call` is one. */
function expectRoot(call: ts.CallExpression): ts.CallExpression | undefined {
  let node: ts.Expression = call.expression;
  while (ts.isPropertyAccessExpression(node) || ts.isCallExpression(node) || ts.isElementAccessExpression(node)) {
    if (isExpectCall(node)) return node as ts.CallExpression;
    node = node.expression;
  }
  return undefined;
}

const COMPARISON = new Set([
  ts.SyntaxKind.EqualsEqualsEqualsToken,
  ts.SyntaxKind.ExclamationEqualsEqualsToken,
  ts.SyntaxKind.EqualsEqualsToken,
  ts.SyntaxKind.ExclamationEqualsToken,
]);

/** Token copies in one test or gallery source (`rel` is under src/, `../test/...` for webviews/test). */
export function tsTokenCopies(rel: string, source: string): Finding[] {
  const ast = ts.createSourceFile(rel, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const findings: Finding[] = [];
  const at = (node: ts.Node) => ast.getLineAndCharacterOfPosition(node.getStart(ast)).line + 1;
  const visit = (node: ts.Node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      const value = normalizePxMs(node.text);
      if (value) {
        let context: string | undefined;
        let hint: string | undefined;
        let outer: ts.Node = node;
        while (
          ts.isParenthesizedExpression(outer.parent) ||
          ts.isAsExpression(outer.parent) ||
          ts.isConditionalExpression(outer.parent)
        )
          outer = outer.parent;
        const parent = outer.parent;
        const key =
          ts.isPropertyAssignment(parent) && parent.initializer === outer
            ? ts.isIdentifier(parent.name) || ts.isStringLiteral(parent.name)
              ? parent.name.text
              : undefined
            : undefined;
        if (key !== undefined) {
          if (key.startsWith("--")) {
            // A custom property set to a value is a token definition, not a copy.
          } else {
            // A style object: `style={{ gap: "2px" }}`, or an object an assertion compares.
            let object: ts.Node = parent.parent;
            const styleAttr =
              ts.isObjectLiteralExpression(object) &&
              ts.isJsxExpression(object.parent) &&
              ts.isJsxAttribute(object.parent.parent) &&
              ts.isIdentifier(object.parent.parent.name) &&
              object.parent.parent.name.text === "style";
            while (object.parent && !ts.isCallExpression(object) && !ts.isStatement(object)) object = object.parent;
            const asserted = ts.isCallExpression(object) && (isExpectCall(object) || expectRoot(object));
            if (styleAttr || asserted) {
              context = styleAttr ? "style" : "expect";
              hint = kebab(key);
            }
          }
        } else if (ts.isCallExpression(parent) && parent.arguments.includes(outer as ts.Expression)) {
          const root = isExpectCall(parent) ? parent : expectRoot(parent);
          if (root) {
            context = "expect";
            hint = propertyHint(root.arguments.map((arg) => arg.getText(ast)).join(" "));
          }
        } else if (ts.isBinaryExpression(parent) && COMPARISON.has(parent.operatorToken.kind)) {
          context = "compare";
          hint = propertyHint((parent.left === outer ? parent.right : parent.left).getText(ast));
        }
        if (context) {
          // A test's left/top/right/bottom is mostly a position the code computed, not a spacing token.
          const positional = hint !== undefined && context !== "style" && /^(?:top|right|bottom|left|inset)/.test(hint);
          const family: TokenFamily | undefined = value.endsWith("ms")
            ? hint === undefined || propertyFamily(hint) === "duration"
              ? "duration"
              : undefined
            : hint === undefined || positional
              ? undefined
              : STROKE_SHORTHAND.test(hint)
                ? "stroke"
                : propertyFamily(hint);
          const around = parent.getText(ast).slice(0, 400);
          const icon = /icon|glyph|svg/i.test(around);
          // A value on the adopted scale is the scale's, as in CSS; only an off-scale value a token names is a copy.
          const sanctioned = family !== undefined && onScale(family, value, icon);
          const token = family && !sanctioned && tokenFor(rel, value, family, around, icon);
          if (token)
            findings.push({
              file: rel,
              kind: "token-copy",
              selector: context,
              property: context,
              value,
              line: at(node),
              token: token.name,
              sheet: token.sheet,
            });
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

export function findTokenCopies(): Finding[] {
  return [
    ...cssFiles().flatMap(cssTokenCopies),
    ...testAndGalleryFiles().flatMap((file) =>
      tsTokenCopies(relative(SRC, file).replaceAll("\\", "/"), readFileSync(file, "utf8")),
    ),
  ];
}

/**
 * Motion literals in scripts (kind `motion-literal`): a TS or TSX file, tests and galleries included,
 * that hand-types a duration or a curve the motion scale names, so a scale change has to find every
 * copy (cmux#39380 moved one value, 265 to 180 ms, in 14 files; Leo, 2026-11-14: "fewer sources of
 * truth for individual things"). The value comes from webviews/src/motion/scale.generated.ts
 * (`MOTION_MS.standard`, `MOTION_SETTLE_MS`, `MOTION_SETTLE`, `MOTION_EASE_OUT`) or from a
 * `var(--cmux-motion-*)` in a CSS string. Counted:
 *   string   a string or template piece with a scale step as a CSS time (80/120/180/240 ms or
 *            0.08/0.12/0.18/0.24 s, "180 ms" in prose too) or the scale's ease-out or settle curve.
 *            A `var(--cmux-motion-*, 180ms)` fallback is the generator's to keep in step
 *            (scripts/cmux-next/gen-motion-scale.py --check), not counted here.
 *   number   a bare 80/120/180/240 bound to a name that reads as a length in ms (`FOLD_MS`,
 *            `durationMs`, `duration:`) or asserted against one (`expect(fold.durationMs).toBe(180)`).
 * A line marked `motion-allow: <reason>` is a reviewed exception (a value that only happens to equal a
 * step, such as a 120 ms debounce). The generated scale itself is not scanned.
 *
 * The steps and curves come from schemas/motion-scale/motion-scale.json, the file a scale change edits,
 * so the detector follows it: a new step value is flagged and a retired one stops being flagged with no
 * edit here (cmux#44271 review).
 */
/** The parts of motion-scale.json the detector reads. */
export type MotionScaleSource = {
  steps: { ms: number }[];
  easeOut: number[];
  settle: { ms: number; bezier: number[] };
  send: { ms: number; ease: number[] };
};
const MOTION_SCALE_JSON = join(ROOT, "..", "schemas", "motion-scale", "motion-scale.json");
/** What a hand-typed copy of `scale` looks like: its durations (ms) and its curves. */
export type MotionScaleMatchers = { ms: Set<number>; curve: RegExp };
export function motionScaleMatchers(scale: MotionScaleSource): MotionScaleMatchers {
  // A 0 ms send is "no motion", not a step anyone copies.
  const ms = new Set(
    [...scale.steps.map((step) => step.ms), scale.settle.ms, scale.send.ms].filter((value) => value > 0),
  );
  const curves = [scale.easeOut, scale.settle.bezier, scale.send.ease];
  const points = (curve: number[]) => curve.map((point) => String(point).replace(".", "\\.")).join("\\s*,\\s*");
  return { ms, curve: new RegExp(`cubic-bezier\\(\\s*(?:${[...new Set(curves.map(points))].join("|")})\\s*\\)`, "g") };
}
const SCALE = motionScaleMatchers(JSON.parse(readFileSync(MOTION_SCALE_JSON, "utf8")) as MotionScaleSource);
const MOTION_TIME = /(?<![\w.$-])(\d*\.?\d+) ?(ms|s)\b/g;
const SCALE_FALLBACK = /var\(\s*--cmux-(?:motion|ease|spinner)-[\w-]+\s*,(?:[^()]|\([^()]*\))*\)/g;
const MS_NAME = /(?:^|_)MS$|[a-z]Ms$|^ms$|[Dd]uration$|DURATION$/;
const MOTION_ALLOW = /motion(?::\s*allow|-allow:)\s*\S/;
/** Generated copies of the scales (motion/scale.generated.ts, ui/designTokens.generated.ts) are the source. */
const SCRIPT_SKIP = /\.generated\.ts$|\.d\.ts$/;

function scriptFiles(): string[] {
  const walk = (dir: string): string[] =>
    existsSync(dir)
      ? readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
          if (entry.isDirectory() && (entry.name === "node_modules" || entry.name === "generated")) return [];
          const path = join(dir, entry.name);
          if (entry.isDirectory()) return walk(path);
          return /\.tsx?$/.test(entry.name) ? [path] : [];
        })
      : [];
  return [...walk(SRC), ...walk(join(ROOT, "test"))].filter((path) => !SCRIPT_SKIP.test(path.replaceAll("\\", "/")));
}

/** The scale-named durations and curves `text` (a string's contents) types out. */
export function motionLiteralsInText(text: string, scale: MotionScaleMatchers = SCALE): string[] {
  const bare = text.replace(SCALE_FALLBACK, "§");
  const found: string[] = [];
  for (const match of bare.matchAll(MOTION_TIME)) {
    const ms = Number(match[1]) * (match[2]!.toLowerCase() === "s" ? 1000 : 1);
    if (scale.ms.has(Math.round(ms * 1000) / 1000)) found.push(match[0]);
  }
  for (const match of bare.matchAll(scale.curve)) found.push(match[0].replace(/\s+/g, " "));
  return found;
}

function bindingName(node: ts.Node): string | undefined {
  const parent = node.parent;
  const name = (n: ts.Node | undefined) =>
    n && (ts.isIdentifier(n) || ts.isStringLiteral(n) || ts.isPrivateIdentifier(n)) ? n.text : undefined;
  if (ts.isVariableDeclaration(parent) || ts.isPropertyAssignment(parent) || ts.isPropertyDeclaration(parent))
    return parent.initializer === node ? name(parent.name) : undefined;
  if (ts.isParameter(parent) && parent.initializer === node) return name(parent.name);
  if (ts.isBinaryExpression(parent) && parent.right === node && parent.operatorToken.kind === ts.SyntaxKind.EqualsToken)
    return ts.isPropertyAccessExpression(parent.left) ? parent.left.name.text : name(parent.left);
  // expect(<subject>).toBe(180): the subject names it.
  if (ts.isCallExpression(parent) && ts.isPropertyAccessExpression(parent.expression)) {
    const matcher = parent.expression.name.text;
    const target = parent.expression.expression;
    if (
      /^to(?:Be|Equal|BeCloseTo|BeLessThanOrEqual|BeGreaterThanOrEqual)$/.test(matcher) &&
      ts.isCallExpression(target)
    ) {
      const subject = target.arguments[0];
      if (subject && ts.isIdentifier(target.expression) && target.expression.text === "expect") {
        const last = ts.isPropertyAccessExpression(subject)
          ? subject.name.text
          : ts.isIdentifier(subject)
            ? subject.text
            : "";
        return last || undefined;
      }
    }
  }
  return undefined;
}

/** Hand-typed motion-scale literals in one script (see the header above `motionScaleMatchers`). */
export function scriptMotionFindings(rel: string, source: string): Finding[] {
  const ast = ts.createSourceFile(
    rel,
    source,
    ts.ScriptTarget.Latest,
    true,
    rel.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const lines = source.split("\n");
  const findings: Finding[] = [];
  const push = (node: ts.Node, property: "string" | "number", value: string) => {
    const line = ast.getLineAndCharacterOfPosition(node.getStart(ast)).line + 1;
    if (MOTION_ALLOW.test(lines[line - 1] ?? "") || MOTION_ALLOW.test(lines[line - 2] ?? "")) return;
    findings.push({ file: rel, kind: "motion-literal", selector: "", property, value, line });
  };
  const visit = (node: ts.Node) => {
    if (
      ts.isStringLiteral(node) ||
      ts.isNoSubstitutionTemplateLiteral(node) ||
      ts.isTemplateHead(node) ||
      ts.isTemplateMiddle(node) ||
      ts.isTemplateTail(node) ||
      ts.isJsxText(node)
    ) {
      for (const value of motionLiteralsInText(node.text)) push(node, "string", value);
    } else if (ts.isNumericLiteral(node) && SCALE.ms.has(Number(node.text))) {
      const name = bindingName(node);
      if (name && MS_NAME.test(name)) push(node, "number", node.text);
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function scriptFindings(): Finding[] {
  return scriptFiles().flatMap((file) => {
    const rel = relative(SRC, file).replaceAll("\\", "/");
    return scriptMotionFindings(rel, readFileSync(file, "utf8"));
  });
}

export function findDesignTokenViolations(): Finding[] {
  return [
    ...cssFiles().flatMap(findingsForFile),
    ...glassFindings(),
    ...tsxFindings(),
    ...findTokenCopies(),
    ...scriptFindings(),
  ];
}

function loadBaseline(): Map<string, number> {
  const baseline = new Map<string, number>();
  if (!existsSync(BASELINE)) return baseline;
  for (const raw of readFileSync(BASELINE, "utf8").split("\n")) {
    if (!raw.trim()) continue;
    const row = JSON.parse(raw) as {
      file: string;
      kind: Finding["kind"];
      property: string;
      values: Record<string, number>;
    };
    if (!row.file || !row.kind || !row.property || !row.values || typeof row.values !== "object") {
      throw new Error(`bad baseline row: ${raw}`);
    }
    for (const [value, count] of Object.entries(row.values)) {
      if (!Number.isInteger(count) || count < 0 || !value) throw new Error(`bad baseline row: ${raw}`);
      baseline.set([row.file, row.kind, row.property, value].join("\t"), count);
    }
  }
  return baseline;
}

function counts(findings: Finding[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const finding of findings) {
    const { line: _line, ...withoutLine } = finding;
    const id = key(withoutLine);
    out.set(id, (out.get(id) ?? 0) + 1);
  }
  return out;
}

function writeBaseline(current: Map<string, number>, previous: Map<string, number>): void {
  const grew = [...current.entries()].filter(([id, count]) => count > (previous.get(id) ?? 0));
  if (grew.length && previous.size) {
    for (const [id, count] of grew) console.error(`baseline would grow: ${count} ${id}`);
    throw new Error("design token baseline is a ratchet; fix new violations before updating it");
  }
  const grouped = new Map<
    string,
    { file: string; kind: Finding["kind"]; property: string; values: Record<string, number> }
  >();
  for (const [id, count] of current) {
    const [file, kind, property, value] = id.split("\t") as [string, Finding["kind"], string, string];
    const groupKey = [file, kind, property].join("\t");
    const row = grouped.get(groupKey) ?? { file, kind, property, values: {} };
    row.values[value] = count;
    grouped.set(groupKey, row);
  }
  const rows = [...grouped.values()]
    .sort((a, b) => `${a.file}\t${a.kind}\t${a.property}`.localeCompare(`${b.file}\t${b.kind}\t${b.property}`))
    .map((row) => JSON.stringify(row));
  writeFileSync(BASELINE, `${rows.join("\n")}\n`);
}

/** How to read a token-copy finding: where it is, and the token to use instead. */
export function tokenCopyHint(finding: Finding): string {
  const read = finding.file.includes(".gallery.")
    ? `getComputedStyle(...).getPropertyValue("${finding.token}")`
    : `designTokenValue("${finding.token}") from test/support/gridTokens.ts`;
  const use = finding.property === "expect" || finding.property === "compare" ? read : `var(${finding.token})`;
  return `  token copy: ${finding.file}:${finding.line} ${finding.property} "${finding.value}" is ${finding.token} (${finding.sheet}); use ${use}`;
}

export function ratchetErrors(
  current: Map<string, number>,
  baseline: Map<string, number>,
  findings: Finding[] = [],
): string[] {
  const errors: string[] = [];
  for (const [id, count] of current) {
    const allowed = baseline.get(id) ?? 0;
    if (count > allowed) {
      errors.push(`new design token violation (${count} > ${allowed}): ${id}`);
      for (const finding of findings)
        if (finding.kind === "token-copy" && key(finding) === id) errors.push(tokenCopyHint(finding));
    }
  }
  for (const [id, allowed] of baseline) {
    const count = current.get(id) ?? 0;
    if (count < allowed) errors.push(`baseline can shrink (${count} < ${allowed}); run --update-baseline: ${id}`);
  }
  return errors;
}

function report(current: Map<string, number>, baseline: Map<string, number>, findings: Finding[]): number {
  const errors = ratchetErrors(current, baseline, findings);
  for (const error of errors) console.error(error);
  return errors.filter((error) => !error.startsWith("  ")).length;
}

if (import.meta.main) {
  const currentFindings = findDesignTokenViolations();
  const current = counts(currentFindings);
  const baseline = loadBaseline();
  if (process.argv.includes("--update-baseline")) {
    try {
      writeBaseline(current, baseline);
      console.log(`Design token baseline updated: ${current.size} entries.`);
    } catch (error) {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    }
  } else if (!baseline.size) {
    console.error(
      `Missing ${relative(ROOT, BASELINE)}; run bun scripts/check-design-tokens.ts --update-baseline once.`,
    );
    process.exitCode = 1;
  } else {
    // Token-only surfaces: every finding is an error; no baseline holds one.
    const strict = findTokenOnlyViolations();
    for (const finding of strict)
      console.error(`token-only ${finding.file}:${finding.line} ${finding.property}: ${finding.value}`);
    const errors = report(current, baseline, currentFindings) + strict.length;
    if (!errors) console.log(`Design token ratchet passed: ${currentFindings.length} recorded violations.`);
    process.exitCode = errors ? 1 : 0;
  }
}
