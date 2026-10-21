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
 * A fixed wait is `page.waitForTimeout(…)`, `Bun.sleep(…)`, a `setTimeout` that resolves a
 * `new Promise` after a delay other than 0 (0 only yields to the next macrotask), or a call to a
 * local helper built on one of those. One that must stay says why in a `// fixed-wait: <reason>`
 * comment on its line or the line above.
 *
 * Files from before the rule have a count in fixed-waits-baseline.tsv. A file fails with more
 * unmarked waits than its row, and with fewer until the row is lowered (`--update-baseline`), so
 * the count only moves down. `--update-baseline` refuses to raise a row.
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

/** The delay argument of a fixed wait, or undefined when the call is not one. */
function fixedDelay(call: ts.CallExpression): ts.Expression | null | undefined {
  const callee = call.expression;
  if (ts.isPropertyAccessExpression(callee)) {
    if (callee.name.text === "waitForTimeout") return call.arguments[0] ?? null;
    if (ts.isIdentifier(callee.expression) && callee.expression.text === "Bun" && callee.name.text === "sleep")
      return call.arguments[0] ?? null;
    return undefined;
  }
  if (!ts.isIdentifier(callee) || callee.text !== "setTimeout") return undefined;
  const [callback, delay] = call.arguments;
  if (!callback || isZero(delay) || !delay) return undefined;
  const resolver = promiseResolver(call);
  if (!resolver) return undefined;
  const resolves =
    (ts.isIdentifier(callback) && callback.text === resolver) ||
    ((ts.isArrowFunction(callback) || ts.isFunctionExpression(callback)) &&
      ts.isCallExpression(callback.body) &&
      ts.isIdentifier(callback.body.expression) &&
      callback.body.expression.text === resolver);
  return resolves ? delay : undefined;
}

/** The name of the local function a delay parameter belongs to (`const wait = (ms) => …`). */
function helperName(call: ts.CallExpression, delay: ts.Expression | null): string | undefined {
  if (!delay || !ts.isIdentifier(delay)) return undefined;
  for (let at: ts.Node | undefined = call.parent; at; at = at.parent) {
    if (!ts.isFunctionLike(at)) continue;
    if (!at.parameters.some((parameter) => ts.isIdentifier(parameter.name) && parameter.name.text === delay.text))
      continue;
    if (ts.isFunctionDeclaration(at) && at.name) return at.name.text;
    let holder: ts.Node = at.parent;
    while (ts.isParenthesizedExpression(holder)) holder = holder.parent;
    if (ts.isVariableDeclaration(holder) && ts.isIdentifier(holder.name)) return holder.name.text;
    return undefined;
  }
  return undefined;
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
  const waits: ts.Node[] = [];
  const helpers = new Map<string, ts.Node>();
  function visit(node: ts.Node) {
    if (ts.isCallExpression(node)) {
      const delay = fixedDelay(node);
      if (delay !== undefined) {
        const helper = helperName(node, delay);
        if (helper) helpers.set(helper, node);
        else waits.push(node);
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  if (helpers.size) {
    const calls = (node: ts.Node) => {
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && helpers.has(node.expression.text))
        waits.push(node);
      ts.forEachChild(node, calls);
    };
    calls(source);
  }
  const name = path.relative(root, file);
  return waits
    .map((node) => source.getLineAndCharacterOfPosition(node.getStart(source)).line)
    .filter((line) => !MARKER.test(lines[line] ?? "") && !MARKER.test(lines[line - 1] ?? ""))
    .sort((a, b) => a - b)
    .map((line) => `${name}:${line + 1}`);
}

function readBaseline(): Map<string, number> {
  if (!existsSync(baselinePath)) return new Map();
  return new Map(
    readFileSync(baselinePath, "utf8")
      .split("\n")
      .filter((line) => line && !line.startsWith("#"))
      .map((line) => {
        const [file, count] = line.split("\t");
        return [file!, Number(count)] as const;
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

if (import.meta.main) {
  const found = new Map<string, string[]>();
  function scan(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== "node_modules") scan(file);
      } else if (/[._](?:test|spec)\.[cm]?[jt]sx?$/.test(entry.name) || directory.endsWith("test/support")) {
        const waits = findFixedWaits(file, readFileSync(file, "utf8"));
        if (waits.length) found.set(path.relative(root, file), waits);
      }
    }
  }
  scan(path.join(root, "test"));
  scan(path.join(root, "src"));
  const counts = new Map([...found].map(([file, waits]) => [file, waits.length]));
  const baseline = readBaseline();
  const grew: string[] = [];
  const shrank: string[] = [];
  for (const file of [...new Set([...counts.keys(), ...baseline.keys()])].sort()) {
    const now = counts.get(file) ?? 0;
    const before = baseline.get(file) ?? 0;
    if (now > before)
      grew.push(`  ${file}: ${now} fixed waits, baseline ${before}\n    ${found.get(file)!.join("\n    ")}`);
    else if (now < before) shrank.push(`  ${file}: ${now} fixed waits, baseline ${before}`);
  }
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
