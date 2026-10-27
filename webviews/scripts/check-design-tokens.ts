/**
 * Design-token ratchet for first-party webview surfaces.
 *
 * New literal spacing and control sizes must use the adopted scale. Existing debt is recorded in
 * design-tokens-baseline.tsv; the baseline can only shrink with --update-baseline. Glass fills use
 * the same resolver as check-glass-never-opaque, with named floating surfaces included even while
 * their markup is being migrated to `.ui-glass`.
 */
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { fillKind, glassContextRules, targetsRequiredGlass, type Block } from "./check-glass-never-opaque";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(ROOT, "src");
const BASELINE = join(dirname(fileURLToPath(import.meta.url)), "design-tokens-baseline.jsonl");
const SPACING = new Set([0, 4, 8, 12, 16, 24, 32]);
const CONTROL_HEIGHT = new Set([0, 20, 24, 28, 32]);
const CSS_ROOTS = ["."];
const ROOT_FILES: string[] = [];
const NAMED_GLASS = /\.(?:nt-box|acpmux-env-panel|acpmux-composer-strip|acpmux-composer)\b/;
const SPACING_PROPERTY = /^(?:padding(?:-(?:block|inline|top|right|bottom|left))?|gap|row-gap|column-gap)$/;
const HEIGHT_PROPERTY = /^(?:height|min-height)$/;
const REDUCE_MEDIA = /(?<!not\s*)\(\s*prefers-reduced-transparency\s*:\s*reduce\s*\)/;
const REDUCE_ATTR = /(?<!:not\(\s*)\[data-reduce-transparency\]/;

export interface Finding {
  file: string;
  kind: "spacing" | "height" | "opaque-glass";
  selector: string;
  property: string;
  value: string;
  line: number;
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

function isOutsideScale(property: string, value: string): boolean {
  const values = pxValues(value);
  if (!values.length || value.includes("var(--ds-")) return false;
  const allowed = HEIGHT_PROPERTY.test(property) ? CONTROL_HEIGHT : SPACING;
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
        isOutsideScale(declaration.property, declaration.value)
      ) {
        findings.push({
          file: rel,
          kind: "height",
          selector: block.selector,
          property: declaration.property,
          value: declaration.value,
          line: declaration.line,
        });
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

export function findDesignTokenViolations(): Finding[] {
  return [...cssFiles().flatMap(findingsForFile), ...glassFindings()];
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
