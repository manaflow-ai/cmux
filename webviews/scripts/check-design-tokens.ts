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
 * Font sizes are the type-scale ratchet's job (scripts/cmux-next/check-type-scale.py), not this one's.
 * A migration PR shrinks the baseline with `bun scripts/check-design-tokens.ts --update-baseline`,
 * which refuses to grow any count.
 */
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";
import { fillKind, glassContextRules, targetsRequiredGlass, type Block } from "./check-glass-never-opaque";
import { isIconSelector } from "./check-icon-scale";

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
const COLOR_FUNCTION = /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(/gi;
/** Properties whose strings and idents are not colours (`content: "#1"`). */
const NOT_COLOR_PROPERTY =
  /^(?:(?:-webkit-)?mask(?:-[a-z-]+)?|content|quotes|grid-template-areas|font-feature-settings|font-variation-settings|counter-\w+)$/;
const HEX_COLOR = /#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})\b/i;
const REDUCE_MEDIA = /(?<!not\s*)\(\s*prefers-reduced-transparency\s*:\s*reduce\s*\)/;
const REDUCE_ATTR = /(?<!:not\(\s*)\[data-reduce-transparency\]/;

export interface Finding {
  file: string;
  kind: "spacing" | "height" | "opaque-glass" | "color" | "radius" | "font-weight" | "duration" | "easing";
  selector: string;
  property: string;
  value: string;
  line: number;
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

function pxValues(value: string): number[] {
  return [...value.matchAll(/(-?(?:\d+\.?\d*|\.\d+))px\b/gi)].map((match) => Number(match[1]));
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

/** The literal values an inline style property can take: a string, a number, or either branch of ?: / ??. */
function styleValues(node: ts.Expression, property: string): string[] {
  if (ts.isParenthesizedExpression(node) || ts.isAsExpression(node)) return styleValues(node.expression, property);
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
  if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken)
    return styleValues(node.right, property);
  return [];
}

/** Literal design values in TSX inline `style={{ ... }}` objects, judged like the same CSS declaration. */
export function inlineStyleFindings(rel: string, source: string): Finding[] {
  const ast = ts.createSourceFile(rel, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const findings: Finding[] = [];
  const visit = (node: ts.Node) => {
    if (
      ts.isJsxAttribute(node) &&
      ts.isIdentifier(node.name) &&
      node.name.text === "style" &&
      node.initializer &&
      ts.isJsxExpression(node.initializer) &&
      node.initializer.expression &&
      ts.isObjectLiteralExpression(node.initializer.expression)
    ) {
      for (const prop of node.initializer.expression.properties) {
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

export function findDesignTokenViolations(): Finding[] {
  return [...cssFiles().flatMap(findingsForFile), ...glassFindings(), ...tsxFindings()];
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

export function ratchetErrors(current: Map<string, number>, baseline: Map<string, number>): string[] {
  const errors: string[] = [];
  for (const [id, count] of current) {
    const allowed = baseline.get(id) ?? 0;
    if (count > allowed) errors.push(`new design token violation (${count} > ${allowed}): ${id}`);
  }
  for (const [id, allowed] of baseline) {
    const count = current.get(id) ?? 0;
    if (count < allowed) errors.push(`baseline can shrink (${count} < ${allowed}); run --update-baseline: ${id}`);
  }
  return errors;
}

function report(current: Map<string, number>, baseline: Map<string, number>): number {
  const errors = ratchetErrors(current, baseline);
  for (const error of errors) console.error(error);
  return errors.length;
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
    const errors = report(current, baseline);
    if (!errors) console.log(`Design token ratchet passed: ${currentFindings.length} recorded violations.`);
    process.exitCode = errors ? 1 : 0;
  }
}
