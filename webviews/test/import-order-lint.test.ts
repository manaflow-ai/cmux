// The detector for test files that load src/ before they install their DOM (the class
// test/support/importWithDom.ts explains). Some modules check for a document once, when they first
// load (Floating UI's `isClient`, Base UI's layout effect, react-dom's event names), and `bun test`
// shares one module cache across the files of a process: a file that imports src/ at the top and
// installs jsdom in beforeAll or in its tests loads them browser-less for every later file
// (session-info-motion before session-info-subagent-card-stays: popups that never position, #46384).
//
// A test file that installs a DOM global (window or document assigned onto globalThis, Object.assign
// of them, a `new JSDOM` window put in scope, or the repo's helpers: importWithDom, settings'
// installDom, unknownWrite's useDom) fails here for each module of src/ it loads at module level
// before its first install at module level: a static import (always evaluated before the file's
// body), or a top-level `await import(...)` above the install. A static import of a test helper
// counts too unless PURE_HELPERS lists it. Not counted: `import type`, and imports inside a function
// (a test, beforeAll, a helper), which run when it is called. Every test file under test/ and src/ is
// scanned; files from before the rule are listed in import-order-baseline.txt (BASELINE_FILE below).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import ts from "typescript";

const webviews = resolve(import.meta.dir, "..");

/// Test helpers a file may import before its DOM: they load nothing from src/ and nothing that checks
/// for a document when it loads (only node:, bun:, jsdom, playwright, React's scheduler, each other).
/// The last test below keeps this list honest. Paths from webviews/, without the extension.
export const PURE_HELPERS = new Set([
  "test/support/domTeardown", // React's scheduler only (resolved from react-dom's folder)
  "test/support/importWithDom", // jsdom only: the fix itself
  "test/support/jsdomScroller",
  "test/support/paintedFrames", // a Playwright page script
  "test/support/rowPropsRenders", // no imports: counts a row's renders by its props
  "test/support/settingsCardSizes", // no imports: the settings cards' row sizes
  "test/support/until",
  "test/support/virtualSizes", // no imports: gives jsdom a viewport and row heights
  // The settings pages' DOM install (a top-level `installDom()`, then `await import` of the rest). It
  // loads the settings string table first, a plain lookup that reads no global when it loads.
  "src/pages/settings/testDom",
]);

/// The ratchet: test files from before the rule that still load src/ before their DOM, one path per
/// line (from webviews/; `#` starts a comment). A listed file may stay out of order; any other file
/// out of order fails, and a listed file that is now in order fails until its line is deleted, so the
/// list only shrinks. A new test file is never added to it: load src/ after the DOM instead.
export const BASELINE_FILE = "test/import-order-baseline.txt";

/// The repo's DOM-install helpers. A top-level call of settings' `installDom` installs the DOM there.
/// unknownWrite's `useDom` installs in the beforeAll it registers, and importWithDom only for the load
/// it wraps (its import is inside a function, so it never counts), so a call of either marks a file
/// with a DOM but is not an install the imports below it can rely on.
const INSTALL_CALLS = new Set(["installDom"]);
const LATER_INSTALL_CALLS = new Set(["useDom", "importWithDom"]);
const DOM_KEYS = new Set(["window", "document"]);

const keyName = (name: ts.PropertyName | ts.Expression): string | undefined =>
  ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNoSubstitutionTemplateLiteral(name) ? name.text : undefined;

const isFunctionLike = (node: ts.Node): boolean => ts.isFunctionLike(node) || ts.isClassLike(node);

const objectHasDomKey = (node: ts.ObjectLiteralExpression): boolean =>
  node.properties.some((property) => property.name !== undefined && DOM_KEYS.has(keyName(property.name) ?? ""));

type Scan = {
  /// Object literals bound by name in the file (`const replacements = { window, document }`).
  domObjects: Set<string>;
  /// File-local functions that install a DOM global when called.
  installers: Set<string>;
};

/// Whether `node` itself (not its children) puts window or document onto a global.
function installsHere(node: ts.Node, scan: Scan, calls: Set<string>): boolean {
  if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
    const left = node.left;
    if (ts.isPropertyAccessExpression(left)) return DOM_KEYS.has(left.name.text);
    if (ts.isElementAccessExpression(left)) return DOM_KEYS.has(keyName(left.argumentExpression) ?? "");
  }
  if (!ts.isCallExpression(node)) return false;
  const callee = node.expression;
  if (ts.isIdentifier(callee)) return calls.has(callee.text) || scan.installers.has(callee.text);
  if (!ts.isPropertyAccessExpression(callee)) return false;
  const name = callee.getText();
  if (name === "GlobalRegistrator.register") return true;
  const args = node.arguments.slice(1);
  if (name === "Object.defineProperty") return DOM_KEYS.has(keyName(node.arguments[1] ?? callee) ?? "");
  if (name !== "Object.assign" && name !== "Object.defineProperties") return false;
  return args.some(
    (arg) =>
      (ts.isObjectLiteralExpression(arg) && objectHasDomKey(arg)) ||
      (ts.isIdentifier(arg) && scan.domObjects.has(arg.text)),
  );
}

/// Whether anything under `node` installs, not descending into functions when `topLevel`.
function installsUnder(node: ts.Node, scan: Scan, calls: Set<string>, topLevel: boolean): boolean {
  if (installsHere(node, scan, calls)) return true;
  if (topLevel && isFunctionLike(node)) return false;
  return ts.forEachChild(node, (child) => installsUnder(child, scan, calls, topLevel) || undefined) ?? false;
}

function scanOf(file: ts.SourceFile): Scan {
  const scan: Scan = { domObjects: new Set(), installers: new Set() };
  const visit = (node: ts.Node) => {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      if (ts.isObjectLiteralExpression(node.initializer) && objectHasDomKey(node.initializer))
        scan.domObjects.add(node.name.text);
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  // A local function that installs, called at the top level, installs there (`function installDom()`).
  for (let changed = true; changed;) {
    changed = false;
    const visitFunctions = (node: ts.Node) => {
      let name: string | undefined;
      let body: ts.Node | undefined;
      if (ts.isFunctionDeclaration(node) && node.name) [name, body] = [node.name.text, node.body];
      if (
        ts.isVariableDeclaration(node) &&
        ts.isIdentifier(node.name) &&
        node.initializer &&
        ts.isFunctionLike(node.initializer)
      )
        [name, body] = [node.name.text, node.initializer];
      if (name && body && !scan.installers.has(name) && installsUnder(body, scan, INSTALL_CALLS, false)) {
        scan.installers.add(name);
        changed = true;
      }
      ts.forEachChild(node, visitFunctions);
    };
    visitFunctions(file);
  }
  return scan;
}

/// webviews/-relative path of a relative specifier, without its extension; undefined for packages.
function target(specifier: string, fileName: string): string | undefined {
  if (!specifier.startsWith(".")) return undefined;
  return relative(webviews, resolve(webviews, dirname(fileName), specifier)).replace(/\.(?:tsx?|jsx?|mjs)$/, "");
}

/// Whether loading `specifier` from `fileName` can load src/ (or a helper that does).
function loadsSource(specifier: string, fileName: string): string | undefined {
  const path = target(specifier, fileName);
  // Data (a strings table, a stylesheet) runs no code; another test file is not a helper.
  if (!path || PURE_HELPERS.has(path) || /\.(?:css|json)$/.test(path) || path.endsWith(".test")) return undefined;
  return path.startsWith("src/") || path.startsWith("test/") ? path : undefined;
}

const typeOnly = (node: ts.ImportDeclaration): boolean => {
  const clause = node.importClause;
  if (!clause) return false;
  if (clause.isTypeOnly) return true;
  const bindings = clause.namedBindings;
  return (
    !clause.name &&
    !!bindings &&
    ts.isNamedImports(bindings) &&
    bindings.elements.length > 0 &&
    bindings.elements.every((element) => element.isTypeOnly)
  );
};

export type ImportOrderFinding = { line: number; loads: string; message: string };

/// The findings for one test file's source: each module-level load of src/ before the file's DOM.
export function importOrderFindings(source: string, fileName: string): ImportOrderFinding[] {
  const file = ts.createSourceFile(
    fileName,
    source,
    ts.ScriptTarget.Latest,
    true,
    fileName.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const scan = scanOf(file);
  const allCalls = new Set([...INSTALL_CALLS, ...LATER_INSTALL_CALLS]);
  const makesDom = /\bnew JSDOM\(/.test(source) || installsUnder(file, scan, allCalls, false);
  if (!makesDom) return [];

  const findings: ImportOrderFinding[] = [];
  const add = (node: ts.Node, specifier: string, loads: string, how: string) => {
    const line = file.getLineAndCharacterOfPosition(node.getStart(file)).line + 1;
    findings.push({
      line,
      loads,
      message:
        `${fileName}:${line}: ${how} ${specifier} before the file installs its DOM, so a module that checks for a ` +
        `document when it loads sees none, in this file and in every later file of the bun process. Load it after ` +
        `the install: \`await importWithDom(() => import("${specifier}"))\` (test/support/importWithDom), an ` +
        `\`await import\` below a top-level install, or an import inside beforeAll; \`import type\` for types.`,
    });
  };

  // Static imports run first, in order, before any statement of the file.
  for (const statement of file.statements) {
    const declaration =
      ts.isImportDeclaration(statement) || (ts.isExportDeclaration(statement) && statement.moduleSpecifier)
        ? statement
        : undefined;
    if (!declaration || (ts.isImportDeclaration(declaration) && typeOnly(declaration))) continue;
    if (ts.isExportDeclaration(declaration) && declaration.isTypeOnly) continue;
    const specifier = (declaration.moduleSpecifier as ts.StringLiteral).text;
    const loads = loadsSource(specifier, fileName);
    if (loads) add(declaration, specifier, loads, "imports");
  }

  // Then the body: a top-level `await import()` counts until the first top-level install.
  let installed = false;
  const visit = (node: ts.Node): void => {
    if (installed || isFunctionLike(node)) return;
    if (installsHere(node, scan, INSTALL_CALLS)) {
      installed = true;
      return;
    }
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      const argument = node.arguments[0];
      if (argument && ts.isStringLiteralLike(argument)) {
        const loads = loadsSource(argument.text, fileName);
        if (loads) add(node, argument.text, loads, "loads (top-level await import)");
      }
    }
    ts.forEachChild(node, visit);
  };
  for (const statement of file.statements) if (!ts.isImportDeclaration(statement)) visit(statement);
  return findings;
}

function testFiles(): string[] {
  const listed = Bun.spawnSync(
    [
      "git",
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      "test/*.test.ts",
      "test/*.test.tsx",
      "src/*.test.ts",
      "src/*.test.tsx",
    ],
    { cwd: webviews, stdout: "pipe" },
  );
  return new TextDecoder()
    .decode(listed.stdout)
    .split("\0")
    .filter((name) => name && !name.startsWith("test/support/"));
}

export function baselineOf(text: string): string[] {
  return text
    .split("\n")
    .map((line) => line.replace(/#.*/, "").trim())
    .filter(Boolean);
}

// One test per offending file, named by the file (dom-teardown-lint.test.ts says why: a new offender is
// a new red name, not one more line in an old red).
const files = testFiles();
const findingsOf = new Map(
  files.map((name) => [name, importOrderFindings(readFileSync(resolve(webviews, name), "utf8"), name)]),
);
const baseline = baselineOf(readFileSync(resolve(webviews, BASELINE_FILE), "utf8"));
const baselined = new Set(baseline);

test("every test file under test/ and src/ is scanned", () => {
  expect(files.filter((name) => name.startsWith("test/")).length).toBeGreaterThan(100);
  expect(files.filter((name) => name.startsWith("src/")).length).toBeGreaterThan(100);
});

for (const [name, findings] of findingsOf) {
  if (findings.length === 0 || baselined.has(name)) continue;
  test(`installs its DOM before it imports src/ > ${name}`, () => {
    expect(findings.map((finding) => finding.message)).toEqual([]);
  });
}

// A file fixed (or deleted) leaves the list in the same change, so the list only shrinks.
test(`every file in ${BASELINE_FILE} still loads src/ before its DOM (delete the lines of fixed files)`, () => {
  const stale = baseline.filter((name) => !findingsOf.get(name)?.length);
  expect(stale).toEqual([]);
  expect(baseline.length).toBe(baselined.size);
});

test("every pure helper imports nothing from src/ and only other pure helpers", () => {
  const impure: string[] = [];
  for (const helper of PURE_HELPERS) {
    if (helper === "src/pages/settings/testDom") continue; // the settings install, by design (above)
    const fileName = `${helper}.ts`;
    const source = readFileSync(resolve(webviews, fileName), "utf8");
    const file = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true);
    const visit = (node: ts.Node): void => {
      const specifier =
        (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
        node.moduleSpecifier &&
        ts.isStringLiteral(node.moduleSpecifier)
          ? node.moduleSpecifier.text
          : ts.isCallExpression(node) &&
              node.expression.kind === ts.SyntaxKind.ImportKeyword &&
              node.arguments[0] &&
              ts.isStringLiteralLike(node.arguments[0])
            ? node.arguments[0].text
            : undefined;
      if (specifier && loadsSource(specifier, fileName)) impure.push(`${fileName}: ${specifier}`);
      ts.forEachChild(node, visit);
    };
    visit(file);
  }
  expect(impure).toEqual([]);
});

const name = "test/fixture.test.tsx";
const lines = (source: string) => importOrderFindings(source, name).map((finding) => finding.line);

test("the rule flags src/ loaded before the DOM", () => {
  // session-info-motion's shape: static imports, the DOM installed inside each test.
  const perTest = `import { JSDOM } from "jsdom";
import { SessionInfo } from "../src/session-info/SessionInfo";
function installDom() {
  const dom = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
}
test("opens", () => { installDom(); });
`;
  expect(lines(perTest)).toEqual([2]);
  expect(importOrderFindings(perTest, name)[0]!.message).toContain(
    `${name}:2: imports ../src/session-info/SessionInfo before`,
  );
  expect(importOrderFindings(perTest, name)[0]!.message).toContain("importWithDom");
  // A static import is evaluated before a top-level install however low the install sits.
  expect(lines(`import { a } from "../src/a";\nconst dom = new JSDOM("");\nglobalThis.window = dom.window;\n`)).toEqual(
    [1],
  );
  // A top-level await import above the install, also inside a top-level block.
  expect(
    lines(
      `const dom = new JSDOM("");\n{ const { a } = await import("../src/a"); }\n(globalThis as any).document = dom.window.document;\n`,
    ),
  ).toEqual([2]);
  // beforeAll installs, through a replacements object or the unknownWrite helper.
  const replacements = `import { a } from "../src/a";\nconst values = { window: w, document: d };\nbeforeAll(() => { Object.assign(scope, values); });\nconst w = new JSDOM("").window;\n`;
  expect(lines(replacements)).toEqual([1]);
  expect(lines(`import { useDom } from "./support/unknownWrite";\nimport { a } from "../src/a";\nuseDom();\n`)).toEqual(
    [1, 2],
  );
  // importWithDom's DOM is gone once its load ends: an await import after it still has none.
  expect(
    lines(
      `const { a } = await importWithDom(() => import("../src/a"));\nconst { b } = await import("../src/b");\nbeforeAll(() => { globalThis.window = w; });\n`,
    ),
  ).toEqual([2]);
  // A value and a type from one import still load the module.
  expect(lines(`import { a, type B } from "../src/a";\nglobalThis.document = d;\n`)).toEqual([1]);
});

test("the rule passes the DOM installed first, type imports, imports in functions, and pure helpers", () => {
  const head = `import { JSDOM } from "jsdom";\nimport type { Snapshot } from "../src/model";\nimport { type Row } from "../src/rows";\nimport { teardownDom } from "./support/domTeardown";\nimport { importWithDom } from "./support/importWithDom";\n`;
  expect(
    lines(
      `${head}const { SessionInfo } = await importWithDom(() => import("../src/SessionInfo"));\nbeforeAll(() => { globalThis.window = new JSDOM("").window; });\n`,
    ),
  ).toEqual([]);
  // The settings pages' pattern: a top-level install, then await import.
  expect(
    lines(
      `import { installDom } from "../src/pages/settings/testDom";\nconst restore = installDom();\nconst { keys } = await import("../src/pages/settings/keys");\n`,
    ),
  ).toEqual([]);
  // A file-local install function called at the top level, then await import.
  expect(
    lines(
      `${head}function install() { Object.assign(globalThis, { document: new JSDOM("").window.document }); }\ninstall();\nconst { a } = await import("../src/a");\n`,
    ),
  ).toEqual([]);
  // Imports inside beforeAll or a test run when called, after the install.
  expect(
    lines(
      `${head}beforeAll(async () => { globalThis.window = new JSDOM("").window; await import("../src/a"); });\ntest("x", async () => { await import("../src/b"); });\n`,
    ),
  ).toEqual([]);
  // No DOM of its own: not this class.
  expect(lines(`import { a } from "../src/a";\ntest("x", () => {});\n`)).toEqual([]);
  // Packages and other test files are not src/.
  expect(
    lines(
      `import { createRoot } from "react-dom/client";\nimport { cases } from "./cases.test";\nglobalThis.document = d;\n`,
    ),
  ).toEqual([]);
});

test("a test helper that is not on the pure list counts as src/", () => {
  expect(lines(`import { useDom } from "./support/unknownWrite";\nuseDom();\n`)).toEqual([1]);
  expect(lines(`import { until } from "./support/until";\nglobalThis.document = d;\n`)).toEqual([]);
});

test("a test file under src/ counts its relative imports as src/", () => {
  const colocated = "src/pages/settings/keys.test.tsx";
  const at = (source: string) => importOrderFindings(source, colocated).map((finding) => finding.line);
  expect(at(`import { keyRows } from "./keys";\nbeforeAll(() => { globalThis.document = d; });\n`)).toEqual([1]);
  expect(
    at(
      `import { installDom } from "./testDom";\nconst restore = installDom();\nconst { keyRows } = await import("./keys");\n`,
    ),
  ).toEqual([]);
});

test("the baseline reads one path per line, comments and blank lines aside", () => {
  expect(baselineOf("# heading\n\ntest/a.test.tsx\nsrc/b.test.ts  # why\n")).toEqual([
    "test/a.test.tsx",
    "src/b.test.ts",
  ]);
});
