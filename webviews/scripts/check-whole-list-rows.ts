import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import ts from "typescript";
import { fileURLToPath } from "node:url";

/**
 * Whole-list row ratchet: a row reads its own entry, never the whole list. A row component that takes
 * `sessions` as a prop, reads `snapshot.sessions`, binds a list from a hook (`useSyncExternalStore`,
 * `useContext`, `useSessions()`), or runs `.find(` or `.filter(` over one re-runs on every change to
 * any entry and does O(N) work for its own one, so one session's change costs more as sessions grow
 * (webviews/bench/update-one.bench.ts: 8 ms to 20 ms per change from 100 to 3,000 sessions). Read the
 * row's entry by id from a keyed store (`useSyncExternalStore(store.subscribe(id), () => store.get(id))`),
 * or pass the entry itself as the prop.
 *
 * A row component is a function component in a .tsx file under src/ whose name ends in Row, Item, Card
 * or Cell, or one the same file renders inside a `.map(` callback (prototypes, galleries and tests are
 * skipped). A whole list is a name in WHOLE_LISTS (`sessions`, `asks`, `workspaces`, `panes`) read as a
 * prop, a property (`x.sessions`), a hook's binding (`const sessions = useSessions()`) or the receiver of
 * `.find(`, `.filter(`, `.findIndex(`, `.some(` or `.every(`; or `rows` or `items` read off a snapshot
 * (`snapshot.rows`) or bound from `useSyncExternalStore` or `useContext`. A plain `group.rows` or
 * `block.items` is a group's own children and is not one. A read that must stay says why in a
 * `// whole-list-ok: <why>` comment in its statement or on a comment line just above it; a marker on
 * the line above the component covers all of it.
 *
 * Files from before the rule have a count in whole-list-rows-baseline.tsv. A file fails with more
 * unmarked reads than its row, and with fewer until the row is lowered (`--update-baseline`), so the
 * count only moves down. `--update-baseline` refuses to raise a row.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const baselinePath = path.join(root, "scripts/whole-list-rows-baseline.tsv");
const MARKER = /\/\/\s*whole-list-ok:\s*\S/;
const ROW_NAME = /^[A-Z]\w*(?:Row|Item|Card|Cell)$/;
/** Names that always mean a whole collection of the app's sessions, asks, workspaces or panes. */
export const WHOLE_LISTS = new Set(["sessions", "allSessions", "sessionList", "asks", "workspaces", "panes", "allRows", "allItems"]);
/**
 * Names that are a whole list only when read off the app's snapshot (`snapshot.rows`) or bound from a store
 * subscription (`useSyncExternalStore`, `useContext`): elsewhere `rows` and `items` are usually a group's own
 * children (`group.rows`, `block.items`), which a group row may read.
 */
export const SNAPSHOT_LISTS = new Set(["rows", "items"]);
const SNAPSHOTS = new Set(["snapshot", "paneSnapshot", "appSnapshot"]);
const STORE_HOOKS = new Set(["useSyncExternalStore", "useContext"]);
const SCANS = new Set(["find", "filter", "findIndex", "findLast", "some", "every"]);

/** The name a function component is declared under, if `node` is one. */
function componentName(node: ts.Node): string | undefined {
  if (ts.isFunctionDeclaration(node)) return node.name?.text;
  if (!ts.isArrowFunction(node) && !ts.isFunctionExpression(node)) return undefined;
  if (ts.isFunctionExpression(node) && node.name) return node.name.text;
  // `const XRow = (…) => …`, `const XRow = memo(function (…) …)`, `forwardRef(…)`.
  let holder: ts.Node = node.parent;
  while (holder && (ts.isParenthesizedExpression(holder) || ts.isCallExpression(holder) || ts.isAsExpression(holder)))
    holder = holder.parent;
  return holder && ts.isVariableDeclaration(holder) && ts.isIdentifier(holder.name) ? holder.name.text : undefined;
}

/** Component names the file renders as a JSX tag inside a `.map(` callback. */
function mappedComponents(source: ts.SourceFile): Set<string> {
  const found = new Set<string>();
  const visit = (node: ts.Node, inMap: boolean) => {
    if (inMap && (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node))) {
      const tag = node.tagName;
      if (ts.isIdentifier(tag) && /^[A-Z]/.test(tag.text)) found.add(tag.text);
    }
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === "map"
    ) {
      ts.forEachChild(node, (child) => visit(child, inMap || node.arguments.includes(child as ts.Expression)));
      return;
    }
    ts.forEachChild(node, (child) => visit(child, inMap));
  };
  visit(source, false);
  return found;
}

/** The whole-list name an expression reads directly: `sessions`, `snapshot.sessions`, `props.rows`. */
function listName(node: ts.Expression): string | undefined {
  while (ts.isNonNullExpression(node) || ts.isParenthesizedExpression(node)) node = node.expression;
  if (ts.isIdentifier(node)) return WHOLE_LISTS.has(node.text) ? node.text : undefined;
  if (ts.isPropertyAccessExpression(node) && isListRead(node)) return node.name.text;
  return undefined;
}

/** Whether a property read is a whole list: `x.sessions`, or `snapshot.rows`. */
function isListRead(node: ts.PropertyAccessExpression): boolean {
  const name = node.name.text;
  if (WHOLE_LISTS.has(name)) return true;
  let receiver = node.expression;
  while (ts.isNonNullExpression(receiver) || ts.isParenthesizedExpression(receiver)) receiver = receiver.expression;
  const host = ts.isIdentifier(receiver)
    ? receiver.text
    : ts.isPropertyAccessExpression(receiver)
      ? receiver.name.text
      : "";
  return SNAPSHOT_LISTS.has(name) && SNAPSHOTS.has(host);
}

/** Whole-list names a binding pattern introduces (`{ sessions }`, `{ rows: list }`, `sessions`). */
function boundLists(name: ts.BindingName, lists: (name: string) => boolean): ts.Node[] {
  if (ts.isIdentifier(name)) return lists(name.text) ? [name] : [];
  const out: ts.Node[] = [];
  for (const element of name.elements) {
    if (ts.isOmittedExpression(element)) continue;
    const key = element.propertyName && ts.isIdentifier(element.propertyName) ? element.propertyName.text : undefined;
    if (key && lists(key)) out.push(element);
    else out.push(...boundLists(element.name, lists));
  }
  return out;
}

const strong = (name: string) => WHOLE_LISTS.has(name);
const strongOrSnapshot = (name: string) => WHOLE_LISTS.has(name) || SNAPSHOT_LISTS.has(name);

/** The hook a call names (`useX(…)`, `React.useX(…)`), if it is one. */
function hookName(node: ts.Expression): string | undefined {
  while (ts.isNonNullExpression(node) || ts.isParenthesizedExpression(node) || ts.isAsExpression(node))
    node = node.expression;
  if (!ts.isCallExpression(node)) return undefined;
  const callee = node.expression;
  const name = ts.isIdentifier(callee)
    ? callee.text
    : ts.isPropertyAccessExpression(callee)
      ? callee.name.text
      : "";
  return /^use[A-Z]/.test(name) ? name : undefined;
}

/** The statement a node sits in: its lines are where a marker may go. */
function statementOf(node: ts.Node): ts.Node {
  let at = node;
  while (at.parent && !ts.isBlock(at.parent) && !ts.isSourceFile(at.parent) && !ts.isCaseClause(at.parent))
    at = at.parent;
  return at;
}

/** Each unmarked whole-list read in a row component of a .tsx source, as `file:line`. */
export function findWholeListRows(file: string, text: string): string[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const lines = text.split("\n");
  const line = (position: number) => source.getLineAndCharacterOfPosition(position).line;
  // A marker on the comment line above the node's statement, or on a line from that statement's start to
  // `end` (the node's last line; a component's own header line, so a marker in its body covers one read).
  const markedAt = (node: ts.Node, end = node.getEnd()) => {
    const statement = statementOf(node);
    const first = line(statement.getStart(source));
    const above = lines[first - 1] ?? "";
    if (/^\s*(?:\/\/|\{?\/\*)/.test(above) && MARKER.test(above)) return true;
    for (let at = first; at <= line(end); at++) if (MARKER.test(lines[at] ?? "")) return true;
    return false;
  };
  const mapped = mappedComponents(source);
  const hits = new Set<number>();

  const checkComponent = (fn: ts.SignatureDeclaration & { body?: ts.Node }) => {
    if (markedAt(fn, fn.getStart(source))) return;
    const hit = (node: ts.Node) => {
      if (!markedAt(node)) hits.add(line(node.getStart(source)));
    };
    // Props: `({ sessions })`, `({ snapshot: { sessions } })`.
    const props = fn.parameters[0];
    if (props) for (const node of boundLists(props.name, strong)) hit(node);
    const visit = (node: ts.Node) => {
      // A nested component is checked on its own.
      if (node !== fn && ts.isFunctionLike(node) && componentName(node) && isRowComponent(node)) return;
      const hook = ts.isVariableDeclaration(node) && node.initializer ? hookName(node.initializer) : undefined;
      if (hook && ts.isVariableDeclaration(node))
        for (const bound of boundLists(node.name, STORE_HOOKS.has(hook) ? strongOrSnapshot : strong)) hit(bound);
      else if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        SCANS.has(node.expression.name.text) &&
        listName(node.expression.expression)
      )
        hit(node);
      else if (ts.isPropertyAccessExpression(node) && isListRead(node) && !ts.isCallExpression(node.parent)) hit(node);
      ts.forEachChild(node, visit);
    };
    if (fn.body) ts.forEachChild(fn.body, visit);
  };
  const isRowComponent = (node: ts.Node) => {
    const name = componentName(node);
    return !!name && /^[A-Z]/.test(name) && (ROW_NAME.test(name) || mapped.has(name));
  };
  const walk = (node: ts.Node) => {
    if (ts.isFunctionLike(node) && isRowComponent(node)) checkComponent(node as ts.SignatureDeclaration);
    ts.forEachChild(node, walk);
  };
  walk(source);
  const name = path.relative(root, file);
  return [...hits].sort((a, b) => a - b).map((at) => `${name}:${at + 1}`);
}

export function readBaseline(text = existsSync(baselinePath) ? readFileSync(baselinePath, "utf8") : ""): Map<
  string,
  number
> {
  return new Map(
    text
      .split("\n")
      .filter((row) => row && !row.startsWith("#"))
      .map((row) => {
        const [file, count] = row.split("\t");
        if (!file || !/^\d+$/.test(count ?? "")) throw new Error(`whole-list-rows-baseline.tsv: bad row "${row}"`);
        return [file, Number(count)] as const;
      }),
  );
}

function writeBaseline(counts: Map<string, number>) {
  const rows = [...counts].filter(([, count]) => count > 0).sort(([a], [b]) => a.localeCompare(b));
  writeFileSync(
    baselinePath,
    "# Whole-list reads per file in row components from before the rule (scripts/check-whole-list-rows.ts). Only moves down.\n" +
      rows.map(([file, count]) => `${file}\t${count}`).join("\n") +
      "\n",
  );
}

/** Files above their baseline row (with their reads) and below it; a row whose file is gone is neither. */
export function compareToBaseline(
  found: Map<string, string[]>,
  baseline: Map<string, number>,
  exists: (file: string) => boolean,
): { grew: string[]; shrank: string[] } {
  const grew: string[] = [];
  const shrank: string[] = [];
  for (const file of [...new Set([...found.keys(), ...baseline.keys()])].sort()) {
    const now = found.get(file)?.length ?? 0;
    const before = baseline.get(file) ?? 0;
    if (!found.has(file) && !exists(file)) continue;
    if (now > before)
      grew.push(`  ${file}: ${now} whole-list reads in rows, baseline ${before}\n    ${found.get(file)!.join("\n    ")}`);
    else if (now < before) shrank.push(`  ${file}: ${now} whole-list reads in rows, baseline ${before}`);
  }
  return { grew, shrank };
}

/** Every .tsx under src/ that is product code (not a test, gallery fixture or generated file). */
export function scanSources(directory = path.join(root, "src")): Map<string, string[]> {
  const found = new Map<string, string[]>();
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (!["node_modules", "generated", "fixtures", "gallery", "prototype", "prototypes", "__tests__"].includes(entry.name))
        for (const [k, v] of scanSources(file)) found.set(k, v);
    } else if (/\.tsx$/.test(entry.name) && !/[._](?:test|spec|gallery|stories)\.tsx$/.test(entry.name)) {
      const reads = findWholeListRows(file, readFileSync(file, "utf8"));
      if (reads.length) found.set(path.relative(root, file), reads);
    }
  }
  return found;
}

if (import.meta.main) {
  const found = scanSources();
  const counts = new Map([...found].map(([file, reads]) => [file, reads.length]));
  const { grew, shrank } = compareToBaseline(found, readBaseline(), (file) => existsSync(path.join(root, file)));
  if (process.argv.includes("--update-baseline")) {
    if (grew.length && existsSync(baselinePath)) {
      console.error("check-whole-list-rows: refusing to raise the baseline; read the row's own entry instead:");
      console.error(grew.join("\n"));
      process.exit(1);
    }
    writeBaseline(counts);
    console.log(`check-whole-list-rows: baseline written (${counts.size} files)`);
    process.exit(0);
  }
  if (grew.length) {
    console.error(
      'check-whole-list-rows: a row component reads a whole list, so one entry\'s change costs O(N) and re-runs every row. Pass the row its own entry, or read it by id from a keyed store (useSyncExternalStore(store.subscribe(id), () => store.get(id))); a read that must stay says why in a "// whole-list-ok: <why>" comment:',
    );
    console.error(grew.join("\n"));
  }
  if (shrank.length) {
    console.error(
      "check-whole-list-rows: fewer whole-list reads than the baseline; lower it (bun scripts/check-whole-list-rows.ts --update-baseline):",
    );
    console.error(shrank.join("\n"));
  }
  if (grew.length || shrank.length) process.exitCode = 1;
  else
    console.log(
      `Whole-list row reads checked (${[...counts.values()].reduce((a, b) => a + b, 0)} on the baseline).`,
    );
}
