import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import ts from "typescript";
import { fileURLToPath } from "node:url";

/**
 * Fixed-wait ratchet: a test waits for a condition (an event, a DOM state, a painted frame), never a
 * fixed number of milliseconds. A fixed wait passes on an idle machine and fails on a loaded CI
 * runner that wakes it late, or passes while hiding the bug it waits out (#23323: a 200 ms wait
 * woke after the card's 250 ms delay). Where the timing is itself the behavior under test, use fake
 * timers or measure against the timer, not the wall clock.
 *
 * A fixed wait is `page.waitForTimeout(…)`, `Bun.sleep(…)`, or a `setTimeout` that resolves a
 * `new Promise` after a delay other than 0 (0 only yields to the next macrotask). Each one counts,
 * and so does each use of a local helper built on one (a call, or the helper passed as a value),
 * inside other helpers too, so a new wait anywhere raises the count. One that must stay says why in
 * a `// fixed-wait: <reason>` comment within its statement or on a comment line just above it.
 *
 * Files from before the rule have a count in fixed-waits-baseline.tsv. A file fails with more
 * unmarked waits than its row, and with fewer until the row is lowered (`--update-baseline`), so
 * the count only moves down. `--update-baseline` refuses to raise a row. A row whose file is gone
 * passes (a deleted test hides no wait; a renamed one is counted under its new name) and is dropped
 * on the next `--update-baseline`.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const baselinePath = path.join(root, "scripts/fixed-waits-baseline.tsv");
const MARKER = /\/\/\s*fixed-wait:\s*\S/;

function isZero(node: ts.Expression | undefined): boolean {
  return !!node && ts.isNumericLiteral(node) && Number(node.text.replaceAll("_", "")) === 0;
}

/** The enclosing function's resolver: the first parameter of a `new Promise(executor)` executor. */
function promiseResolver(node: ts.Node): string | undefined {
  for (let at: ts.Node | undefined = node.parent; at; at = at.parent) {
    if (!ts.isArrowFunction(at) && !ts.isFunctionExpression(at)) continue;
    const owner = at.parent;
    const first = at.parameters[0];
    if (
      owner &&
      ts.isNewExpression(owner) &&
      ts.isIdentifier(owner.expression) &&
      owner.expression.text === "Promise" &&
      first &&
      ts.isIdentifier(first.name)
    )
      return first.name.text;
    return undefined;
  }
  return undefined;
}

const TIMER_HOSTS = new Set(["window", "globalThis", "self"]);

/** Whether `node` calls `name` anywhere inside it. */
function calls(node: ts.Node, name: string): boolean {
  if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === name) return true;
  return ts.forEachChild(node, (child) => calls(child, name) || undefined) ?? false;
}

/** The delay argument of a fixed wait, `null` for one with no argument, undefined when it is not one. */
function fixedDelay(call: ts.CallExpression): ts.Expression | null | undefined {
  const callee = call.expression;
  let timer = ts.isIdentifier(callee) && callee.text === "setTimeout";
  if (ts.isPropertyAccessExpression(callee)) {
    const host = ts.isIdentifier(callee.expression) ? callee.expression.text : "";
    if (callee.name.text === "waitForTimeout") return call.arguments[0] ?? null;
    if (host === "Bun" && (callee.name.text === "sleep" || callee.name.text === "sleepSync"))
      return call.arguments[0] ?? null;
    timer = TIMER_HOSTS.has(host) && callee.name.text === "setTimeout";
  }
  if (!timer) return undefined;
  const [callback, delay] = call.arguments;
  if (!callback || !delay || isZero(delay)) return undefined;
  const resolver = promiseResolver(call);
  if (!resolver) return undefined;
  const resolves =
    (ts.isIdentifier(callback) && callback.text === resolver) ||
    ((ts.isArrowFunction(callback) || ts.isFunctionExpression(callback)) && calls(callback.body, resolver));
  return resolves ? delay : undefined;
}

/** A named function in the file: a declaration, or a function assigned to a const. */
type Named = { name: string; node: ts.SignatureDeclaration };

/** The innermost named function around `node`, if any (a test's anonymous callback is not one). */
function enclosingNamed(node: ts.Node): Named | undefined {
  for (let at: ts.Node | undefined = node.parent; at; at = at.parent) {
    if (!ts.isFunctionLike(at)) continue;
    if (ts.isFunctionDeclaration(at) && at.name) return { name: at.name.text, node: at };
    let holder: ts.Node = at.parent;
    while (ts.isParenthesizedExpression(holder)) holder = holder.parent;
    if (ts.isVariableDeclaration(holder) && ts.isIdentifier(holder.name)) return { name: holder.name.text, node: at };
    if (ts.isArrowFunction(at) || ts.isFunctionExpression(at)) continue;
    return undefined;
  }
  return undefined;
}

/** Whether an identifier is the name a declaration introduces, not a use of it. */
function isDeclarationName(node: ts.Identifier): boolean {
  const parent = node.parent;
  if (ts.isExportSpecifier(parent)) return true;
  return (
    (ts.isVariableDeclaration(parent) ||
      ts.isFunctionDeclaration(parent) ||
      ts.isParameter(parent) ||
      ts.isBindingElement(parent) ||
      ts.isFunctionExpression(parent) ||
      ts.isMethodDeclaration(parent) ||
      ts.isMethodSignature(parent) ||
      ts.isPropertyDeclaration(parent) ||
      ts.isPropertySignature(parent) ||
      ts.isGetAccessor(parent) ||
      ts.isSetAccessor(parent) ||
      ts.isImportSpecifier(parent)) &&
    parent.name === node
  );
}

/** The statement a node sits in: its lines are where a marker may go. */
function statementOf(node: ts.Node): ts.Node {
  let at = node;
  while (at.parent && !ts.isBlock(at.parent) && !ts.isSourceFile(at.parent) && !ts.isCaseClause(at.parent))
    at = at.parent;
  return at;
}

/** Each unmarked fixed wait in a test source, as `file:line`. */
export function findFixedWaits(file: string, text: string): string[] {
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const lines = text.split("\n");
  const line = (position: number) => source.getLineAndCharacterOfPosition(position).line;
  const marked = (node: ts.Node) => {
    const statement = statementOf(node);
    const first = line(statement.getStart(source));
    const above = lines[first - 1] ?? "";
    if (/^\s*\/\//.test(above) && MARKER.test(above)) return true;
    for (let at = first; at <= line(node.getEnd()); at++) if (MARKER.test(lines[at] ?? "")) return true;
    return false;
  };

  // A wait inside a named function also makes it a helper: each use of it waits (and so on outward).
  // A helper whose delay parameter defaults to 0 waits only when a call passes a delay other than 0,
  // so its own timer is not counted.
  const helpers = new Map<string, { zeroDefaultAt: number | undefined }>();
  const waits: ts.Node[] = [];
  const place = (site: ts.Node, delay: ts.Expression | null) => {
    const named = enclosingNamed(site);
    const index =
      named && delay && ts.isIdentifier(delay)
        ? named.node.parameters.findIndex(
            (parameter) => ts.isIdentifier(parameter.name) && parameter.name.text === delay.text,
          )
        : -1;
    const zeroDefault = index >= 0 && isZero(named!.node.parameters[index]!.initializer);
    if (!zeroDefault) waits.push(site);
    if (named && !helpers.has(named.name)) helpers.set(named.name, { zeroDefaultAt: zeroDefault ? index : undefined });
  };
  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node)) {
      const delay = fixedDelay(node);
      if (delay !== undefined && !marked(node)) place(node, delay);
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  // A use of a helper: a call, or the helper passed or returned as a value (`act(settle)`,
  // `return { open }`), which something then calls with no arguments.
  const waitingUse = (node: ts.Node): string | undefined => {
    if (!ts.isIdentifier(node)) return undefined;
    const helper = helpers.get(node.text);
    const parent = node.parent;
    if (!helper || isDeclarationName(node)) return undefined;
    if (ts.isPropertyAccessExpression(parent) && parent.name === node) return undefined;
    if (ts.isPropertyAssignment(parent) && parent.name === node) return undefined;
    if (ts.isTypeQueryNode(parent)) return undefined;
    const zeroAt = helper.zeroDefaultAt;
    if (zeroAt === undefined) return node.text;
    const call = ts.isCallExpression(parent) && parent.expression === node ? parent : undefined;
    const argument = call?.arguments[zeroAt];
    return argument !== undefined && !isZero(argument) ? node.text : undefined;
  };
  for (let known = -1; known !== helpers.size;) {
    known = helpers.size;
    const promote = (node: ts.Node) => {
      const used = waitingUse(node);
      const named = used && enclosingNamed(node);
      if (named && named.name !== used && !helpers.has(named.name) && !marked(node)) place(node as ts.Identifier, null);
      ts.forEachChild(node, promote);
    };
    promote(source);
  }
  // Every unmarked wait counts, and every unmarked use of a helper outside its own body.
  const counted = new Set<ts.Node>(waits);
  const count = (node: ts.Node) => {
    const used = waitingUse(node);
    if (used && enclosingNamed(node)?.name !== used && !marked(node)) counted.add(node);
    ts.forEachChild(node, count);
  };
  count(source);
  const name = path.relative(root, file);
  return [...counted]
    .map((node) => line(node.getStart(source)))
    .sort((a, b) => a - b)
    .map((at) => `${name}:${at + 1}`);
}

function readBaseline(): Map<string, number> {
  if (!existsSync(baselinePath)) return new Map();
  return new Map(
    readFileSync(baselinePath, "utf8")
      .split("\n")
      .filter((line) => line && !line.startsWith("#"))
      .map((line) => {
        const [file, count] = line.split("\t");
        if (!file || !/^\d+$/.test(count ?? "")) throw new Error(`fixed-waits-baseline.tsv: bad row "${line}"`);
        return [file, Number(count)] as const;
      }),
  );
}

function writeBaseline(counts: Map<string, number>) {
  const rows = [...counts].filter(([, count]) => count > 0).sort(([a], [b]) => a.localeCompare(b));
  writeFileSync(
    baselinePath,
    "# Fixed waits per test file from before the rule (scripts/check-fixed-waits.ts). Only moves down.\n" +
      rows.map(([file, count]) => `${file}\t${count}`).join("\n") +
      "\n",
  );
}

/** Files above their baseline row (with their waits) and below it; a row whose file is gone is neither. */
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
      grew.push(`  ${file}: ${now} fixed waits, baseline ${before}\n    ${found.get(file)!.join("\n    ")}`);
    else if (now < before) shrank.push(`  ${file}: ${now} fixed waits, baseline ${before}`);
  }
  return { grew, shrank };
}

if (import.meta.main) {
  const found = new Map<string, string[]>();
  // Every source under test/ (tests, harnesses, support and latency helpers; fixtures are data),
  // and the tests beside src/ code.
  function scan(directory: string, all: boolean) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== "node_modules" && entry.name !== "fixtures") scan(file, all);
      } else if (all ? /\.[cm]?[jt]sx?$/.test(entry.name) : /[._](?:test|spec)\.[cm]?[jt]sx?$/.test(entry.name)) {
        const waits = findFixedWaits(file, readFileSync(file, "utf8"));
        if (waits.length) found.set(path.relative(root, file), waits);
      }
    }
  }
  scan(path.join(root, "test"), true);
  scan(path.join(root, "src"), false);
  const counts = new Map([...found].map(([file, waits]) => [file, waits.length]));
  const { grew, shrank } = compareToBaseline(found, readBaseline(), (file) => existsSync(path.join(root, file)));
  if (process.argv.includes("--update-baseline")) {
    if (grew.length && existsSync(baselinePath)) {
      console.error("check-fixed-waits: refusing to raise the baseline; wait for a condition instead:");
      console.error(grew.join("\n"));
      process.exit(1);
    }
    writeBaseline(counts);
    console.log(`check-fixed-waits: baseline written (${counts.size} files)`);
    process.exit(0);
  }
  if (grew.length) {
    console.error(
      'check-fixed-waits: a test waits a fixed time. Wait for the condition instead (an event, a DOM state, a painted frame), use fake timers when the timing is the behavior, or say why it must stay in a "// fixed-wait: <reason>" comment:',
    );
    console.error(grew.join("\n"));
  }
  if (shrank.length) {
    console.error(
      "check-fixed-waits: fewer fixed waits than the baseline; lower it (bun run check:fixed-waits --update-baseline):",
    );
    console.error(shrank.join("\n"));
  }
  if (grew.length || shrank.length) process.exitCode = 1;
  else console.log(`Fixed waits checked (${[...counts.values()].reduce((a, b) => a + b, 0)} on the baseline).`);
}
