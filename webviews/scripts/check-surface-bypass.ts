import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

/**
 * Surface-bypass ratchet: a surface is built from the shared primitives in src/ui/ (`<Surface role=...>`
 * from ui/surface, `<Button>`, `<Tooltip>`), never from its own shell. A surface that styles its own shell
 * cannot be themed, which is how the ask card, the toasts and the diff backgrounds came to look unrelated
 * (Leo, 2026-11-22: "we dont have a system.").
 *
 * Four kinds, counted per file outside src/ui/ (galleries and tests are exempt):
 *   raw-button         a raw `<button` element in a .tsx file; use `<Button>` from ui/Button.
 *   title-attribute    a `title=` attribute on an element (a native tooltip: slow, unstyled, unthemed); use
 *                      `<Tooltip>` from ui/Tooltip.
 *   own-shell          a CSS rule that declares `backdrop-filter`, or `box-shadow` and `border-radius` together
 *                      with a background, and no `--surface-` variable; use `<Surface role=...>` from ui/surface.
 *   surface-override   a `--surface-<role>-*` declaration or a `.ui-surface` selector outside src/ui/ and
 *                      outside a theme file (src/theme/, theme*.css); a role's values come from
 *                      schemas/surface-roles/surface-roles.json, a look overrides them in its theme.
 *
 * Existing debt is a count per file and kind in surface-bypass-baseline.jsonl. A file fails with more than
 * its row, and with fewer until the row is lowered (`--update-baseline`), so the count only moves down;
 * `--update-baseline` refuses to raise a row. A file that is gone passes, and its row is dropped on the next
 * update. This check has no GUARD_OVERRIDE (neither do its siblings): the way past a finding is the primitive.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const SRC = join(ROOT, "src");
const BASELINE = join(HERE, "surface-bypass-baseline.jsonl");
const UPDATE = "bun scripts/check-surface-bypass.ts --update-baseline";

export type Kind = "raw-button" | "title-attribute" | "own-shell" | "surface-override";
export interface Finding {
  file: string;
  line: number;
  kind: Kind;
}

const USE: Record<Kind, string> = {
  "raw-button": "use <Button> from ui/Button (src/ui/Button.tsx)",
  "title-attribute": "use <Tooltip> from ui/Tooltip instead of a native title attribute",
  "own-shell": "use <Surface role=...> from ui/surface; its role sets material, fill, stroke, radius and elevation",
  "surface-override":
    "a role's values live in schemas/surface-roles/surface-roles.json; override them in a theme file, not in a feature's sheet",
};

/** Files the rule does not apply to: the primitives themselves, galleries and tests. */
export function exempt(file: string): boolean {
  return (
    file.startsWith("ui/") ||
    /\.(?:test|spec|gallery|bench)\.|\.gallery\b/.test(file) ||
    /(?:^|\/)(?:__tests__|test|tests)\//.test(file)
  );
}

/** A theme file may override the role variables: src/theme/ and theme*.css, at any depth. */
export function isThemeFile(file: string): boolean {
  return /(?:^|\/)theme\//.test(file) || /(?:^|\/)theme[\w.-]*\.css$/.test(file) || file.startsWith("theme/");
}

/** Raw `<button` elements and `title=` attributes on intrinsic elements in one TSX source. */
export function findJsxBypasses(file: string, text: string): Finding[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const out: Finding[] = [];
  const line = (node: ts.Node) => source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
  const visit = (node: ts.Node) => {
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      const tag = node.tagName;
      if (ts.isIdentifier(tag) && /^[a-z]/.test(tag.text)) {
        if (tag.text === "button") out.push({ file, line: line(node), kind: "raw-button" });
        for (const attribute of node.attributes.properties)
          if (ts.isJsxAttribute(attribute) && ts.isIdentifier(attribute.name) && attribute.name.text === "title")
            out.push({ file, line: line(attribute), kind: "title-attribute" });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return out;
}

interface Rule {
  selector: string;
  line: number;
  keyframes: boolean;
  decls: { prop: string; value: string; line: number }[];
}

/** Every rule that has declarations of its own, nesting and at-rules included; comments and strings are skipped. */
export function parseRules(text: string): Rule[] {
  const rules: Rule[] = [];
  const stack: Rule[] = [];
  let buf = "";
  let line = 1;
  let bufLine = 1;
  const flush = () => {
    const decl = buf.trim();
    buf = "";
    const colon = decl.indexOf(":");
    const rule = stack.at(-1);
    if (rule && colon > 0)
      rule.decls.push({
        prop: decl.slice(0, colon).trim().toLowerCase(),
        value: decl.slice(colon + 1).trim(),
        line: bufLine,
      });
  };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (ch === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      const comment = text.slice(i, end < 0 ? text.length : end + 2);
      line += comment.split("\n").length - 1;
      i += comment.length - 1;
      continue;
    }
    if (ch === '"' || ch === "'") {
      const end = text.indexOf(ch, i + 1);
      const quoted = text.slice(i, end < 0 ? text.length : end + 1);
      if (!buf.trim()) bufLine = line;
      buf += quoted;
      i += quoted.length - 1;
      continue;
    }
    if (ch === "\n") line++;
    if (ch === "{") {
      const selector = buf.trim().replace(/\s+/g, " ");
      const keyframes = /^@(?:-webkit-)?(?:keyframes|font-face)/.test(selector) || (stack.at(-1)?.keyframes ?? false);
      const rule: Rule = { selector, line: bufLine, keyframes, decls: [] };
      buf = "";
      rules.push(rule);
      stack.push(rule);
    } else if (ch === "}") {
      flush();
      stack.pop();
    } else if (ch === ";") flush();
    else {
      if (!buf.trim()) bufLine = line;
      buf += ch;
    }
  }
  return rules;
}

const SURFACE_VAR = /--surface-[a-z][\w]*-[\w-]+/i;

/** Own-shell and surface-override findings in one stylesheet. */
export function findCssBypasses(file: string, text: string): Finding[] {
  const out: Finding[] = [];
  const theme = isThemeFile(file);
  for (const rule of parseRules(text)) {
    if (rule.keyframes) continue;
    const props = new Set(rule.decls.map((decl) => decl.prop));
    const usesRole = rule.decls.some((decl) => SURFACE_VAR.test(decl.value));
    if (!theme) {
      for (const decl of rule.decls)
        if (/^--surface-[a-z][\w]*-[\w-]+$/i.test(decl.prop))
          out.push({ file, line: decl.line, kind: "surface-override" });
      if (/\.ui-surface(?![\w-])/.test(rule.selector)) out.push({ file, line: rule.line, kind: "surface-override" });
    }
    if (usesRole) continue;
    const backdrop = rule.decls.find(
      (decl) => /^(?:-webkit-)?backdrop-filter$/.test(decl.prop) && !/^none\b/.test(decl.value),
    );
    const fill = rule.decls.some(
      (decl) =>
        (decl.prop === "background" || decl.prop === "background-color") &&
        !/^(?:none|transparent|inherit|unset)\b/.test(decl.value),
    );
    if (backdrop) out.push({ file, line: backdrop.line, kind: "own-shell" });
    else if (props.has("box-shadow") && props.has("border-radius") && fill)
      out.push({ file, line: rule.decls.find((decl) => decl.prop === "box-shadow")!.line, kind: "own-shell" });
  }
  return out;
}

function walk(dir: string, accept: (name: string) => boolean): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory())
      return entry.name === "node_modules" || entry.name === "generated" ? [] : walk(join(dir, entry.name), accept);
    return accept(entry.name) ? [join(dir, entry.name)] : [];
  });
}

/** Every finding under `src` (relative paths use `/`), exempt files left out. */
export function findBypasses(src: string = SRC): Finding[] {
  const out: Finding[] = [];
  for (const path of walk(src, (name) => /\.(?:tsx|css)$/.test(name))) {
    const file = relative(src, path).split("\\").join("/");
    if (exempt(file)) continue;
    const text = readFileSync(path, "utf8");
    out.push(...(file.endsWith(".css") ? findCssBypasses(file, text) : findJsxBypasses(file, text)));
  }
  return out;
}

export function counts(findings: Finding[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const { file, kind } of findings) out.set(`${file}\t${kind}`, (out.get(`${file}\t${kind}`) ?? 0) + 1);
  return out;
}

export function loadBaseline(path: string = BASELINE): Map<string, number> {
  const out = new Map<string, number>();
  if (!existsSync(path)) return out;
  for (const row of readFileSync(path, "utf8").split("\n")) {
    if (!row.trim()) continue;
    const { file, kind, count } = JSON.parse(row) as { file: string; kind: Kind; count: number };
    out.set(`${file}\t${kind}`, count);
  }
  return out;
}

/** Errors: a file over its row (with each finding, what to use and the override), or under it. */
export function ratchetErrors(
  current: Map<string, number>,
  baseline: Map<string, number>,
  findings: Finding[],
  exists: (file: string) => boolean = (file) => existsSync(join(SRC, file)),
): string[] {
  const errors: string[] = [];
  for (const [id, count] of current) {
    const allowed = baseline.get(id) ?? 0;
    if (count <= allowed) continue;
    const [file, kind] = id.split("\t") as [string, Kind];
    errors.push(`new surface bypass (${count} > ${allowed}): ${file} ${kind}`);
    for (const finding of findings)
      if (finding.file === file && finding.kind === kind)
        errors.push(`  ${file}:${finding.line} ${kind}: ${USE[kind]}`);
    errors.push(`  override (a finding that must stay, with a reason in the PR): ${UPDATE}`);
  }
  for (const [id, allowed] of baseline) {
    const [file] = id.split("\t") as [string];
    if (!current.has(id) && !exists(file)) continue;
    const count = current.get(id) ?? 0;
    if (count < allowed)
      errors.push(`baseline can shrink (${count} < ${allowed}); run ${UPDATE}: ${id.replace("\t", " ")}`);
  }
  return errors;
}

function writeBaseline(current: Map<string, number>, previous: Map<string, number>): void {
  const grew = [...current].filter(([id, count]) => count > (previous.get(id) ?? 0));
  if (grew.length && previous.size) {
    for (const [id, count] of grew) console.error(`baseline would grow: ${count} ${id.replace("\t", " ")}`);
    throw new Error("surface bypass baseline is a ratchet; build on the ui/ primitive before updating it");
  }
  const rows = [...current]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([id, count]) => {
      const [file, kind] = id.split("\t") as [string, Kind];
      return JSON.stringify({ file, kind, count });
    });
  writeFileSync(BASELINE, `${rows.join("\n")}\n`);
}

if (import.meta.main) {
  const findings = findBypasses();
  const current = counts(findings);
  const baseline = loadBaseline();
  const totals = (map: Map<string, number>) => {
    const sum: Record<string, number> = {};
    for (const [id, count] of map) {
      const kind = id.split("\t")[1]!;
      sum[kind] = (sum[kind] ?? 0) + count;
    }
    return JSON.stringify(sum);
  };
  if (process.argv.includes("--update-baseline")) {
    try {
      writeBaseline(current, baseline);
      console.log(`Surface bypass baseline updated: ${current.size} rows ${totals(current)}.`);
    } catch (error) {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    }
  } else if (!baseline.size) {
    console.error(`Missing ${relative(ROOT, BASELINE)}; run ${UPDATE} once.`);
    process.exitCode = 1;
  } else {
    const errors = ratchetErrors(current, baseline, findings);
    for (const error of errors) console.error(error);
    if (errors.length) process.exitCode = 1;
    else console.log(`Surface bypass ratchet passed: ${totals(current)} on the baseline.`);
  }
}
