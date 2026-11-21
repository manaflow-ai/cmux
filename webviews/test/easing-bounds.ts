// The scanner behind test/easing-bounds.test.ts (Lawrence: no bounce in any motion). It finds every
// easing the webviews declare and gives each one as a function of time, so the test can sample it:
// - every `cubic-bezier(...)` and `linear(...)` easing function in the CSS files under src (comments
//   left out), whatever declares it: a custom property (`--cmux-ease-spring`), a `transition`, an
//   `animation`, a timing function (one whose arguments are not numbers is reported by scanUnreadCss:
//   the test cannot pass a curve it cannot sample);
// - the same functions in the strings of .ts and .tsx files (a Web Animations `easing`, an exported
//   constant such as MOTION_SPRING, CSS in a template string);
// - a cubic-bezier written as four numbers in script (`STEP_CURVE = [0.3, 0.2, 0, 1]`, a tunable's
//   `defaultValue` and `presets`, the curve handed to `animateScrollBy`), found by the names around it.
// It reads source and samples curves; it starts no browser. The CSS keywords (`ease`, `ease-in`,
// `ease-out`, `ease-in-out`, `linear`) are fixed curves: KEYWORD_EASINGS gives them for the test.
// `steps()` holds each value between 0 and 1 by definition and is not read.
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

export const SRC = path.resolve(import.meta.dir, "../src");

/** How far past its end (or under its start) a sample may be: 1e-6 of the travel. */
export const BOUND_TOLERANCE = 1e-6;
/** Samples per easing, besides a `linear()` easing's own stops. */
export const SAMPLES = 2000;

export interface Easing {
  /** Path under src, with forward slashes. */
  file: string;
  /** 1-based line of the easing in its file. */
  line: number;
  /** The easing as written: `cubic-bezier(0.34, 1.4, 0.64, 1)`. */
  text: string;
  /** Progress at each sample, in time order: 0 is the start value and 1 is the end value. */
  samples: number[];
}

export interface EasingRange {
  low: number;
  high: number;
}

export const rangeOf = (samples: readonly number[]): EasingRange => ({
  low: Math.min(...samples),
  high: Math.max(...samples),
});

/** Whether every sample stays between the start (0) and the end (1) of the travel. */
export const withinBounds = (samples: readonly number[]): boolean => {
  const { low, high } = rangeOf(samples);
  return low >= -BOUND_TOLERANCE && high <= 1 + BOUND_TOLERANCE;
};

// --- curves -----------------------------------------------------------------------------------

/**
 * A cubic-bezier easing's progress over its run. The curve is sampled along its parameter: with both
 * x control values in 0...1 time only runs forward, so the progress values in time order are the y
 * values in parameter order, and no solver is needed to find the largest and the smallest.
 */
export function sampleBezier(y1: number, y2: number, count = SAMPLES): number[] {
  const samples: number[] = [];
  for (let index = 0; index <= count; index += 1) {
    const t = index / count;
    samples.push(3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t ** 2 * y2 + t ** 3);
  }
  return samples;
}

/** A piecewise-linear easing's progress: `count + 1` even samples in time, and each stop's own value. */
export function sampleStops(stops: ReadonlyArray<readonly [number, number]>, count = SAMPLES): number[] {
  const at = (x: number): number => {
    if (x <= stops[0]![0]) return stops[0]![1];
    for (let index = 1; index < stops.length; index += 1) {
      const [x1, y1] = stops[index]!;
      if (x > x1) continue;
      const [x0, y0] = stops[index - 1]!;
      return x1 === x0 ? y1 : y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
    }
    return stops.at(-1)![1];
  };
  const samples: number[] = [];
  for (let index = 0; index <= count; index += 1) samples.push(at(index / count));
  return [...samples, ...stops.map(([, value]) => value)];
}

const NUMBER = /^-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?$/i;

/** The four control values of `cubic-bezier(...)`'s arguments, or undefined when they are not four numbers. */
export function parseBezierArguments(inner: string): [number, number, number, number] | undefined {
  const parts = inner.split(",").map((part) => part.trim());
  if (parts.length !== 4 || !parts.every((part) => NUMBER.test(part))) return undefined;
  const [x1, y1, x2, y2] = parts.map(Number) as [number, number, number, number];
  // CSS takes x in 0...1 only; anything else is not an easing.
  return x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1 ? undefined : [x1, y1, x2, y2];
}

/**
 * The stops of `linear(...)`'s arguments as [time 0...1, progress], or undefined when they are not a
 * CSS linear easing (a script call such as `linear(r)` is not one). As CSS reads them: a stop is a
 * number with up to two percentages; the first stop without one is at 0%, the last at 100%, the ones
 * between are spaced evenly, and a time never runs backward.
 */
export function parseLinearArguments(inner: string): [number, number][] | undefined {
  const entries = inner.split(",").map((part) => part.trim().split(/\s+/));
  if (entries.length < 2) return undefined;
  const raw: { value: number; at: number | undefined }[] = [];
  for (const [index, tokens] of entries.entries()) {
    const numbers = tokens.filter((token) => NUMBER.test(token));
    const percents = tokens.filter((token) => token.endsWith("%") && NUMBER.test(token.slice(0, -1)));
    if (numbers.length !== 1 || percents.length > 2 || numbers.length + percents.length !== tokens.length)
      return undefined;
    const value = Number(numbers[0]);
    if (percents.length === 0) {
      raw.push({ value, at: index === 0 ? 0 : index === entries.length - 1 ? 1 : undefined });
      continue;
    }
    for (const percent of percents) raw.push({ value, at: Number(percent.slice(0, -1)) / 100 });
  }
  let latest = 0;
  for (const stop of raw) {
    if (stop.at === undefined) continue;
    stop.at = Math.max(stop.at, latest);
    latest = stop.at;
  }
  for (let index = 0; index < raw.length; index += 1) {
    if (raw[index]!.at !== undefined) continue;
    let next = index;
    while (raw[next]!.at === undefined) next += 1;
    const from = raw[index - 1]!.at!;
    const to = raw[next]!.at!;
    for (let fill = index; fill < next; fill += 1)
      raw[fill]!.at = from + ((to - from) * (fill - index + 1)) / (next - index + 1);
    index = next;
  }
  return raw.map((stop) => [stop.at!, stop.value]);
}

/** The CSS easing keywords as the curves the specification gives them (x1, y1, x2, y2). */
const KEYWORD_CURVES: Record<string, readonly [number, number, number, number]> = {
  linear: [0, 0, 1, 1],
  ease: [0.25, 0.1, 0.25, 1],
  "ease-in": [0.42, 0, 1, 1],
  "ease-out": [0, 0, 0.58, 1],
  "ease-in-out": [0.42, 0, 0.58, 1],
};

/** Each CSS easing keyword's progress over its run. */
export const KEYWORD_EASINGS: Record<string, number[]> = Object.fromEntries(
  Object.entries(KEYWORD_CURVES).map(([keyword, [, y1, , y2]]) => [keyword, sampleBezier(y1, y2)]),
);

// --- source -----------------------------------------------------------------------------------

const SKIP_DIRS = new Set(["node_modules"]);

/** Every .css, .ts and .tsx file under `dir` that ships or shows in the gallery: tests are left out. */
export function easingSourceFiles(dir = SRC): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return SKIP_DIRS.has(entry.name) ? [] : easingSourceFiles(full);
    if (!/\.(css|tsx?)$/.test(entry.name) || entry.name.endsWith(".d.ts")) return [];
    return /\.(test|spec)\.[^.]+$/.test(entry.name) ? [] : [full];
  });
}

const lineAt = (text: string, offset: number) => text.slice(0, offset).split("\n").length;

/** `linear(` not as the tail of another name (`linear-gradient(` has no `linear(`; `--x-linear(` is none). */
const EASING_FUNCTION = /(?<![\w-])(cubic-bezier|linear)\(([^()]*)\)/g;

/** The easing functions in a run of CSS, each on its 1-based line of `text` plus `firstLine - 1`. */
export function easingFunctions(text: string, firstLine = 1): Omit<Easing, "file">[] {
  const found: Omit<Easing, "file">[] = [];
  for (const match of text.matchAll(EASING_FUNCTION)) {
    const [whole, name, inner] = match;
    let samples: number[] | undefined;
    if (name === "cubic-bezier") {
      const curve = parseBezierArguments(inner!);
      if (curve) samples = sampleBezier(curve[1], curve[3]);
    } else {
      const stops = parseLinearArguments(inner!);
      if (stops) samples = sampleStops(stops);
    }
    if (samples)
      found.push({ line: firstLine + lineAt(text, match.index!) - 1, text: whole.replace(/\s+/g, " "), samples });
  }
  return found;
}

/**
 * The easing functions in a run of CSS that `easingFunctions` cannot give as numbers (an argument that
 * is a `var()` or a `calc()`), as `line text`: a curve the test cannot sample is a curve it cannot pass.
 */
export function unreadEasingFunctions(text: string, firstLine = 1): string[] {
  const read = new Set([...text.matchAll(EASING_FUNCTION)].map((match) => match.index));
  const sampled = (offset: number) => {
    if (!read.has(offset)) return false;
    const [, name, inner] = new RegExp(EASING_FUNCTION.source, "y").exec(text.slice(offset))!;
    return (name === "cubic-bezier" ? parseBezierArguments(inner!) : parseLinearArguments(inner!)) !== undefined;
  };
  return [...text.matchAll(/(?<![\w-])(?:cubic-bezier|linear)\(/g)]
    .filter((match) => !sampled(match.index))
    .map((match) => {
      const rest = text.slice(match.index, match.index + 80).split("\n")[0]!;
      return `${firstLine + lineAt(text, match.index) - 1} ${rest.trim()}`;
    });
}

/** `text` with each CSS comment replaced by spaces, line breaks kept, so offsets and lines stay. */
const withoutCssComments = (text: string) =>
  text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));

/**
 * The names around a four-number array that say it is a cubic-bezier curve (`STEP_CURVE`,
 * `treeMarqueeEasing`, `defineTunable`, `animateScrollBy`), and not `release` or `increase`.
 */
const CURVE_NAME =
  /[cC]urve|CURVE|(?<![a-z])ease|Eas(?:e|ing)|(?<![A-Z])EAS(?:E|ING)|[bB]ezier|BEZIER|[tT]unable|animateScroll/;

function numberOf(node: ts.Expression): number | undefined {
  if (ts.isNumericLiteral(node)) return Number(node.text);
  if (
    ts.isPrefixUnaryExpression(node) &&
    node.operator === ts.SyntaxKind.MinusToken &&
    ts.isNumericLiteral(node.operand)
  )
    return -Number(node.operand.text);
  return undefined;
}

/** The names of what holds `node`: its variable, its properties, the functions it is handed to. */
function namesAround(node: ts.Node): string[] {
  const names: string[] = [];
  for (let parent = node.parent; parent && !ts.isSourceFile(parent); parent = parent.parent) {
    if ((ts.isVariableDeclaration(parent) || ts.isPropertyAssignment(parent)) && parent.name)
      names.push(parent.name.getText());
    else if (ts.isCallExpression(parent)) names.push(parent.expression.getText());
  }
  return names;
}

/** The easings in a script: easing functions in its strings, and cubic-bezier curves written as numbers. */
export function scriptEasings(file: string, text: string): Omit<Easing, "file">[] {
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const found: Omit<Easing, "file">[] = [];
  const lineOf = (node: ts.Node) => source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
  const visit = (node: ts.Node): void => {
    if (ts.isStringLiteralLike(node)) {
      found.push(...easingFunctions(node.getText(source), lineOf(node)));
      return;
    }
    if (ts.isTemplateExpression(node)) {
      // The text between the `${...}` parts; each part is blanked (line breaks kept) and read on its
      // own below. An easing built from parts is not numbers here: it is read where its numbers are
      // (the four-number arrays).
      const start = node.getStart(source);
      let written = node.getText(source);
      for (const span of node.templateSpans) {
        const from = span.expression.getFullStart() - start;
        const to = span.expression.getEnd() - start;
        written = written.slice(0, from) + written.slice(from, to).replace(/[^\n]/g, " ") + written.slice(to);
      }
      found.push(...easingFunctions(written, lineOf(node)));
    }
    if (ts.isArrayLiteralExpression(node) && node.elements.length === 4) {
      const values = node.elements.map(numberOf);
      if (values.every((value) => value !== undefined)) {
        const [x1, y1, x2, y2] = values as [number, number, number, number];
        const curve = x1 >= 0 && x1 <= 1 && x2 >= 0 && x2 <= 1;
        if (curve && namesAround(node).some((name) => CURVE_NAME.test(name)))
          found.push({
            line: lineOf(node),
            text: `cubic-bezier as numbers [${values.join(", ")}]`,
            samples: sampleBezier(y1, y2),
          });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return found;
}

/** Every easing the webviews declare, in file and line order. */
export function scanEasings(files = easingSourceFiles()): Easing[] {
  return files.sort().flatMap((full) => {
    const file = path.relative(SRC, full).split(path.sep).join("/");
    const text = fs.readFileSync(full, "utf8");
    const found = full.endsWith(".css") ? easingFunctions(withoutCssComments(text)) : scriptEasings(full, text);
    return found.map((easing) => ({ file, ...easing }));
  });
}

/** Every easing function in the CSS files that the scan cannot sample, as `file:line text`. */
export function scanUnreadCss(files = easingSourceFiles()): string[] {
  return files
    .filter((full) => full.endsWith(".css"))
    .sort()
    .flatMap((full) => {
      const file = path.relative(SRC, full).split(path.sep).join("/");
      return unreadEasingFunctions(withoutCssComments(fs.readFileSync(full, "utf8"))).map((line) => `${file}:${line}`);
    });
}

/** One line per easing that leaves the travel: where it is, what it is, and how far it goes. */
export function describeOutOfBounds(easings: readonly Easing[]): string[] {
  return easings
    .filter((easing) => !withinBounds(easing.samples))
    .map((easing) => {
      const { low, high } = rangeOf(easing.samples);
      const round = (value: number) => Math.round(value * 1e4) / 1e4;
      return `${easing.file}:${easing.line} ${easing.text} (lowest ${round(low)}, highest ${round(high)})`;
    });
}
