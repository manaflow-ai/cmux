// One spelling per agent-pane part. A selector that a `*Selectors.ts` module under src/ exports
// (transcriptSelectors.ts, session-info/sessionInfoSelectors.ts, ...) is that part's only source:
// tests and galleries import the constant. Typed raw, a part's lookup drifts into many spellings, and
// a change to what the part is (Jump up carrying Jump to latest's class, #40454) means rewriting
// every file that typed it. This refuses the raw string in webviews/test and in src/**/*.gallery.* or
// *.test.* files, attribute quoting aside, and names the constant to import.
//
// A lookup inside a function Playwright runs in the page (page.evaluate, waitForFunction,
// addInitScript) cannot see an import: pass the constant in as the function's argument.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function walk(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : walk(full);
    return /\.(ts|tsx)$/.test(entry.name) ? [full] : [];
  });
}

/** `[a='b']`, `[a="b"]` and `[a=b]` are one selector; so are `a>b` and `a > b`. */
export function normalizeSelector(selector: string): string {
  return selector
    .trim()
    .replace(/\[([\w-]+)=(["']?)([^\]"']*)\2\]/g, '[$1="$3"]')
    .replace(/\s*([>+~])\s*/g, " $1 ")
    .replace(/\s+/g, " ");
}

export interface OwnedSelector {
  name: string;
  module: string;
  value: string;
}

export async function ownedSelectors(root = ROOT): Promise<Map<string, OwnedSelector>> {
  const owned = new Map<string, OwnedSelector>();
  for (const file of walk(join(root, "src")).filter((f) => f.endsWith("Selectors.ts"))) {
    const exports = (await import(file)) as Record<string, unknown>;
    for (const [name, value] of Object.entries(exports)) {
      if (typeof value !== "string") continue;
      const key = normalizeSelector(value);
      const prior = owned.get(key);
      if (prior) throw new Error(`${value} is exported twice: ${prior.module} ${prior.name} and ${file} ${name}`);
      owned.set(key, { name, module: file, value });
    }
  }
  return owned;
}

export function checkedFiles(root = ROOT): string[] {
  return [
    ...walk(join(root, "test")),
    ...walk(join(root, "src")).filter((f) => /\.(gallery|test)\.tsx?$/.test(f)),
  ].filter((f) => !f.endsWith("Selectors.ts"));
}

export interface RawSelector {
  file: string;
  line: number;
  start: number;
  end: number;
  owner: OwnedSelector;
}

export function rawSelectors(file: string, text: string, owned: Map<string, OwnedSelector>): RawSelector[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const found: RawSelector[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      const owner = owned.get(normalizeSelector(node.text));
      if (owner) {
        const start = node.getStart(source);
        found.push({ file, line: source.getLineAndCharacterOfPosition(start).line + 1, start, end: node.end, owner });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return found;
}

export function importPath(fromFile: string, module: string): string {
  const path = relative(dirname(fromFile), module).replace(/\.ts$/, "").split(sep).join("/");
  return path.startsWith(".") ? path : `./${path}`;
}

if (import.meta.main) {
  const owned = await ownedSelectors();
  const found = checkedFiles().flatMap((file) => rawSelectors(file, readFileSync(file, "utf8"), owned));
  for (const raw of found) {
    console.error(
      `${relative(ROOT, raw.file)}:${raw.line}: ${JSON.stringify(raw.owner.value)} is ${raw.owner.name}; ` +
        `import { ${raw.owner.name} } from "${importPath(raw.file, raw.owner.module)}" (inside a page function, pass it in as an argument)`,
    );
  }
  if (found.length > 0) {
    console.error(`check-pane-selectors: ${found.length} raw agent-pane selector(s); import the constant instead.`);
    process.exit(1);
  }
  console.log(`check-pane-selectors: ${owned.size} owned selectors, none typed raw in tests or galleries.`);
}
