// The scanner behind test/motion-scale.test.ts (Leo, 2026-10-20: "animations all around are a bit
// slow"). Every timed fade and move of the webviews takes a step of the one motion scale
// (schemas/motion-scale/motion-scale.json, as `--cmux-motion-*` in pages/shared/desktop.css and
// `MOTION_MS` in src/motion/scale.generated.ts): quick 80, micro 120, standard 180, large 240 ms.
// It reads the page code, not a browser:
// - CSS `transition`, `transition-duration`, `animation`, `animation-duration` and custom
//   properties, in .css files and in the strings of .ts and .tsx files;
// - Tailwind `duration-N` and `duration-[…]` classes;
// - the `duration` of a Web Animations `.animate()` call, and constants named like a motion
//   (`FADE_MS`, `GLIDE_MS`, `THOUGHT_FOLD_MS`), when they are numbers in the same file.
// A duration passes when it is 0 (or under 1 ms, Reduce Motion's 0.01ms), a step of the scale, a
// `var(...)` whose literal fallback passes (a `--cmux-motion-<step>` fallback must be that step), or
// a loop of 600 ms or more (an `animation` with `infinite`, an `animation-duration`, a custom
// property named like a period). Delays are not durations: `transition-delay`, `animation-delay`
// and a shorthand's second time (hover intent waits there) are not read. A line marked
// `motion-allow: <reason>` is exempt.
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

export const SRC = path.resolve(import.meta.dir, "../src");
export const SCALE_JSON = path.resolve(import.meta.dir, "../../schemas/motion-scale/motion-scale.json");

export interface MotionScaleJson {
  steps: { name: string; ms: number }[];
  easeOut: number[];
}

export const SCALE: MotionScaleJson = JSON.parse(fs.readFileSync(SCALE_JSON, "utf8"));
const STEPS = new Map(SCALE.steps.map((step) => [step.name, step.ms]));
const ON_SCALE = new Set([0, ...STEPS.values()]);
/** A loop (a spinner turn, a breath, a shimmer pass) is at least this long. */
export const LOOP_MIN_MS = 600;

const ALLOW = /motion-allow:\s*\S/;
/** The gallery is the developer's tool, not the app. */
const SKIP_DIRS = new Set(["gallery", "generated", "node_modules"]);
/** A custom property holding a wait, not a motion. */
const WAIT_NAME = /delay|intent|hold|dwell|wait|grace|timeout/i;
/** A custom property holding a loop's period. */
const LOOP_NAME = /period|loop|spin|breath|pulse|shimmer|sweep|cycle/i;
/** A `var()` without a fallback whose name reads as a duration. */
const DURATION_NAME = /motion|duration|period|fade|speed|-(?:in|out|open|close|hover|focus|move)\b/i;
const NOT_DURATION_NAME = /ease|curve|spring|timing|bezier/i;
/** A JS constant that names a motion's length. */
const MOTION_CONST = /(?:^|_)(?:FADE|FOLD|SHIFT|GLIDE|SLIDE|SWIPE|MOTION|ANIM|ANIMATION|TRANSITION)(?:_[A-Z]+)*_MS$/;
const STYLE_PROPS = new Map([
  ["transition", "transition"],
  ["WebkitTransition", "transition"],
  ["transitionDuration", "transition-duration"],
  ["animation", "animation"],
  ["animationDuration", "animation-duration"],
]);

export interface MotionViolation {
  file: string;
  line: number;
  text: string;
}

export function sourceFiles(dir = SRC): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return SKIP_DIRS.has(entry.name) ? [] : sourceFiles(full);
    if (!/\.(css|tsx?)$/.test(entry.name) || entry.name.endsWith(".d.ts")) return [];
    return /\.(test|spec|gallery)\.[^.]+$/.test(entry.name) ? [] : [full];
  });
}

// --- CSS values -------------------------------------------------------------------------------

/** Splits at `separator` outside parentheses. */
function splitTop(value: string, separator: RegExp): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < value.length; index++) {
    const char = value[index]!;
    if (char === "(") depth++;
    else if (char === ")") depth--;
    else if (depth === 0 && separator.test(char)) {
      parts.push(value.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(value.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

const TIME = /^(-?\d*\.?\d+)(ms|s)$/i;

function literalMs(token: string): number | undefined {
  const match = TIME.exec(token.trim());
  if (!match) return undefined;
  return Number(match[1]) * (match[2]!.toLowerCase() === "s" ? 1000 : 1);
}

/** A `var(--name, fallback)` token's parts. */
function varParts(token: string): { name: string; fallback?: string } | undefined {
  const match = /^var\(\s*(--[\w-]+)\s*(?:,([\s\S]*))?\)$/.exec(token.trim());
  if (!match) return undefined;
  return { name: match[1]!, fallback: match[2]?.trim() || undefined };
}

/** Whether a token of a shorthand is a time (a literal, or a var or calc that holds one). */
function isTimeToken(token: string): boolean {
  if (literalMs(token) !== undefined) return true;
  // A JS expression with a unit (`${MOTION_MS.quick}ms`).
  if (/^var\(--js\)m?s$/.test(token)) return true;
  if (token.startsWith("calc(")) return /\d(?:ms|s)\b|var\(/.test(token);
  const parts = varParts(token);
  if (!parts) return false;
  if (parts.fallback) return isTimeToken(parts.fallback);
  return DURATION_NAME.test(parts.name) && !NOT_DURATION_NAME.test(parts.name);
}

/** Why a duration token is off the scale, or undefined when it passes. */
function durationProblem(token: string, loop: boolean): string | undefined {
  const ms = literalMs(token);
  if (ms !== undefined) {
    if (ms < 1 || ON_SCALE.has(ms)) return undefined;
    if (loop && ms >= LOOP_MIN_MS) return undefined;
    return `${token} is off the scale`;
  }
  const parts = varParts(token);
  if (!parts) return undefined;
  const step = /^--cmux-motion-([\w-]+)$/.exec(parts.name)?.[1];
  if (step !== undefined) {
    const stepMs = STEPS.get(step);
    if (stepMs === undefined) return `${parts.name} is not a step of the scale`;
    const fallback = parts.fallback === undefined ? undefined : literalMs(parts.fallback);
    if (parts.fallback !== undefined && fallback !== stepMs) return `${token}: the fallback is not ${stepMs}ms`;
    return undefined;
  }
  return parts.fallback !== undefined && isTimeToken(parts.fallback)
    ? durationProblem(parts.fallback, loop)
    : undefined;
}

/** The problems of one declaration's value. */
function declarationProblems(property: string, value: string): string[] {
  const problems: string[] = [];
  const add = (problem: string | undefined) => problem && problems.push(problem);
  if (property === "transition-duration") {
    for (const item of splitTop(value, /,/)) add(durationProblem(item, false));
    return problems;
  }
  if (property === "animation-duration") {
    for (const item of splitTop(value, /,/)) add(durationProblem(item, true));
    return problems;
  }
  const custom = property.startsWith("--");
  if (custom && WAIT_NAME.test(property)) return problems;
  for (const layer of splitTop(value, /,/)) {
    const tokens = splitTop(layer, /\s/);
    const loop = property === "animation" ? tokens.includes("infinite") : custom && LOOP_NAME.test(property);
    // The first time is the duration; a second is the delay.
    const duration = tokens.find(isTimeToken);
    if (duration !== undefined) add(durationProblem(duration, loop));
  }
  return problems;
}

const DECLARATION =
  /(?<![\w-])(?:-webkit-)?(transition|transition-duration|animation|animation-duration|--[\w-]+)\s*:\s*([^;{}"'`]*)/g;
const TAILWIND_DURATION = /(?<![\w-])duration-(\d+|\[[^\]\s]+\]|\([^)\s]+\))(?![\w-])/g;

/** A finding, on its 1-based line of the scanned text. */
interface Finding {
  line: number;
  text: string;
}

const lineAt = (text: string, offset: number) => text.slice(0, offset).split("\n").length;

/** Findings in a run of CSS (a stylesheet, or a string in a script). */
function scanCss(text: string): Finding[] {
  const findings: Finding[] = [];
  for (const match of text.matchAll(DECLARATION)) {
    const [whole, property, value] = match;
    for (const problem of declarationProblems(property!, value!.trim()))
      findings.push({ line: lineAt(text, match.index!), text: `${whole.trim()} (${problem})` });
  }
  for (const match of text.matchAll(TAILWIND_DURATION)) {
    const raw = match[1]!;
    const token = raw.startsWith("[")
      ? raw.slice(1, -1)
      : raw.startsWith("(")
        ? `var(${raw.slice(1, -1)})`
        : `${raw}ms`;
    const problem = durationProblem(token, false);
    if (problem) findings.push({ line: lineAt(text, match.index!), text: `${match[0]} (${problem})` });
  }
  return findings;
}

/** CSS with its comments blanked, lines kept. */
function blankCssComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
}

// --- Scripts ----------------------------------------------------------------------------------

/** A number the expression is, when it is a literal or a same-file constant. */
function constantMs(node: ts.Expression, constants: Map<string, ts.Expression>, seen = new Set<string>()): number[] {
  if (ts.isParenthesizedExpression(node)) return constantMs(node.expression, constants, seen);
  if (ts.isNumericLiteral(node)) return [Number(node.text.replace(/_/g, ""))];
  if (ts.isConditionalExpression(node))
    return [...constantMs(node.whenTrue, constants, seen), ...constantMs(node.whenFalse, constants, seen)];
  if (ts.isIdentifier(node) && !seen.has(node.text)) {
    const value = constants.get(node.text);
    if (value) return constantMs(value, constants, new Set([...seen, node.text]));
  }
  if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression)) {
    const object = constants.get(node.expression.text);
    if (object && ts.isObjectLiteralExpression(object)) {
      const property = object.properties.find(
        (entry): entry is ts.PropertyAssignment =>
          ts.isPropertyAssignment(entry) && entry.name.getText() === node.name.text,
      );
      if (property) return constantMs(property.initializer, constants, seen);
    }
  }
  return [];
}

function msProblem(ms: number, loop: boolean): string | undefined {
  if (ms < 1 || ON_SCALE.has(ms) || (loop && ms >= LOOP_MIN_MS)) return undefined;
  return `${ms}ms is off the scale`;
}

/** A string's source text as CSS (raw, so its lines are the file's), each `${…}` as `var(--js)`. */
function stringText(node: ts.Node): string | undefined {
  const file = node.getSourceFile().text;
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node))
    return file.slice(node.getStart() + 1, node.getEnd() - 1);
  if (!ts.isTemplateExpression(node)) return undefined;
  let text = file.slice(node.head.getStart() + 1, node.head.getEnd() - 2);
  for (const span of node.templateSpans) {
    // The substitution's own line breaks stay, so a finding after it keeps its line.
    const substitution = file.slice(span.expression.getFullStart(), span.literal.getStart());
    text += "var(--js)" + "\n".repeat(substitution.split("\n").length - 1);
    const literalEnd = ts.isTemplateTail(span.literal) ? span.literal.getEnd() - 1 : span.literal.getEnd() - 2;
    text += file.slice(span.literal.getStart() + 1, literalEnd);
  }
  return text;
}

function scanScript(file: string, text: string): Finding[] {
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const constants = new Map<string, ts.Expression>();
  const findings: Finding[] = [];
  const at = (node: ts.Node, message: string) =>
    findings.push({
      line: source.getLineAndCharacterOfPosition(node.getStart()).line + 1,
      text: `${node.getText().split("\n")[0]!.slice(0, 120)} (${message})`,
    });

  (function collect(node: ts.Node) {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      let initializer: ts.Expression = node.initializer;
      while (ts.isAsExpression(initializer) || ts.isSatisfiesExpression(initializer))
        initializer = initializer.expression;
      constants.set(node.name.text, initializer);
    }
    ts.forEachChild(node, collect);
  })(source);

  function checkDuration(node: ts.Expression, loop: boolean) {
    for (const ms of constantMs(node, constants)) {
      const problem = msProblem(ms, loop);
      if (problem) at(node, problem);
    }
  }

  function visit(node: ts.Node) {
    const css = stringText(node);
    if (css !== undefined) {
      const line = source.getLineAndCharacterOfPosition(node.getStart()).line;
      for (const finding of scanCss(css)) findings.push({ line: line + finding.line, text: finding.text });
      return;
    }
    // `{ transition: "opacity 150ms" }` and `style.transition = "…"`.
    const styleValue = (name: string, value: ts.Expression) => {
      const property = STYLE_PROPS.get(name);
      const css = property && stringText(value);
      if (property && css !== undefined)
        for (const problem of declarationProblems(property, css.trim())) at(value, problem);
    };
    if (ts.isPropertyAssignment(node) && (ts.isIdentifier(node.name) || ts.isStringLiteral(node.name)))
      styleValue(node.name.text, node.initializer);
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isPropertyAccessExpression(node.left)
    )
      styleValue(node.left.name.text, node.right);
    // A motion constant.
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      MOTION_CONST.test(node.name.text) &&
      node.initializer
    )
      checkDuration(node.initializer, false);
    // `element.animate(keyframes, { duration })` and `element.animate(keyframes, 200)`.
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === "animate" &&
      node.arguments.length === 2
    ) {
      const options = node.arguments[1]!;
      if (ts.isObjectLiteralExpression(options)) {
        const entry = (key: string) =>
          options.properties.find(
            (property): property is ts.PropertyAssignment =>
              ts.isPropertyAssignment(property) && property.name.getText() === key,
          );
        const iterations = entry("iterations")?.initializer.getText();
        const duration = entry("duration");
        if (duration) checkDuration(duration.initializer, iterations === "Infinity");
      } else checkDuration(options, false);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return findings;
}

// --- The scan ---------------------------------------------------------------------------------

export function scanText(file: string, text: string): MotionViolation[] {
  const findings = file.endsWith(".css") ? scanCss(blankCssComments(text)) : scanScript(file, text);
  const lines = text.split("\n");
  return findings
    .map((finding) => ({ line: finding.line, text: finding.text.replace(/\s+/g, " ") }))
    .filter(({ line }) => !ALLOW.test(lines[line - 1] ?? ""))
    .map(({ line, text: findingText }) => ({ file, line, text: findingText }));
}

export function scan(files = sourceFiles()): MotionViolation[] {
  return files.flatMap((full) =>
    scanText(path.relative(SRC, full).split(path.sep).join("/"), fs.readFileSync(full, "utf8")),
  );
}
