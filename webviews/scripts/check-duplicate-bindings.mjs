#!/usr/bin/env node
// No webviews module binds one name twice.
//
// Leo, 2026-11-27: "shouldn't a build check fail beforehand fast like fast-fail is useful ci all stuff".
// Two pull requests that each pass alone merge into a module that names one binding twice, and every web
// check on the base goes red: `layoutGeometry` (2026-11-23..27) and `paneSends` (#51093 after #61160,
// 2026-11-27). tests/test_webviews_no_duplicate_import_names.py reads import lists with regexes, before any
// install; this reads every module with oxc-parser, the parser the web build itself runs, so it catches
// the whole class:
//   - any name declared twice in one scope (`const a` and `let a`, an import listed twice, `const a` and
//     `function a`), the build's own "Identifier `a` has already been declared";
//   - an import whose local name a top-level statement of the same module declares again (`import { a }`
//     and `const a`, `import type { T }` and `type T`): TypeScript's TS2440, which oxc lets pass in a
//     .ts file because the import might be type-only.
//
// Usage: node scripts/check-duplicate-bindings.mjs [DIR...]   (default: src)
//        node scripts/check-duplicate-bindings.mjs --self-test
// cmux-next-compile-preflight runs it on each pull request's head merged onto the live base, and
// check:pieces runs it on every push. oxc-parser 0.132 comes hoisted from webviews/bun.lock (deslop-js needs it);
// pinning it directly would move @oxc-project/types under rolldown, so it is read where the lockfile puts it.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { availableParallelism } from "node:os";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { parseSync } from "oxc-parser";

const HERE = fileURLToPath(new URL("..", import.meta.url));
const SOURCE = /\.(?:[cm]?[jt]sx?)$/;
const SKIP_DIRS = new Set(["node_modules", "dist", "build", "generated-out"]);

// TypeScript lets a name live once in each meaning: `import type { T }` beside `function T` is legal (a
// component and its props type often share a name), `import type { T }` beside `type T` is TS2440, and so
// is a value import beside `const`/`function`. So a declaration is read as the meanings it takes.
const VALUE = 1;
const TYPE = 2;

function declaredNames(stmt) {
  // [name, meanings] for each name a top-level statement declares in the module scope.
  if (!stmt) return [];
  if (stmt.type === "ExportNamedDeclaration" || stmt.type === "ExportDefaultDeclaration") {
    return stmt.declaration ? declaredNames(stmt.declaration) : [];
  }
  if (stmt.declare) return [];
  const named = (meaning) => (stmt.id && stmt.id.type === "Identifier" ? [[stmt.id.name, meaning]] : []);
  switch (stmt.type) {
    case "VariableDeclaration":
      return stmt.declarations.flatMap((d) => patternNames(d.id).map((name) => [name, VALUE]));
    case "FunctionDeclaration":
    case "TSDeclareFunction":
      return named(VALUE);
    case "ClassDeclaration":
    case "TSEnumDeclaration":
      return named(VALUE | TYPE);
    case "TSInterfaceDeclaration":
    case "TSTypeAliasDeclaration":
      return named(TYPE);
    default:
      return [];
  }
}

function patternNames(node) {
  if (!node) return [];
  switch (node.type) {
    case "Identifier":
      return [node.name];
    case "ObjectPattern":
      return node.properties.flatMap((p) => patternNames(p.type === "RestElement" ? p.argument : p.value));
    case "ArrayPattern":
      return node.elements.flatMap((e) => patternNames(e));
    case "RestElement":
      return patternNames(node.argument);
    case "AssignmentPattern":
      return patternNames(node.left);
    default:
      return [];
  }
}

function lineOf(text, offset) {
  let line = 1;
  for (let i = 0; i < offset && i < text.length; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

const OPTIONS = { showSemanticErrors: true };

export function duplicates(filename, text, result = parseSync(filename, text, OPTIONS)) {
  const found = [];
  for (const error of result.errors) {
    if (!/has already been declared/.test(error.message)) continue;
    const at = error.labels?.[0]?.start;
    found.push(`${error.message}${at === undefined ? "" : ` (line ${lineOf(text, at)})`}`);
  }
  const imported = new Map();
  for (const stmt of result.program.body) {
    if (stmt.type !== "ImportDeclaration") continue;
    for (const spec of stmt.specifiers ?? []) {
      // A value import's meaning is whatever the other module exports; read it as a value (a type-only
      // export imported without `type` beside a same-named function is the one legal case this flags).
      const typeOnly = stmt.importKind === "type" || spec.importKind === "type";
      imported.set(spec.local.name, { at: spec.local.start, meaning: typeOnly ? TYPE : VALUE });
    }
  }
  if (imported.size) {
    for (const stmt of result.program.body) {
      for (const [name, meaning] of declaredNames(stmt)) {
        const imp = imported.get(name);
        if (!imp || !(imp.meaning & meaning)) continue;
        found.push(
          `Identifier \`${name}\` is imported (line ${lineOf(text, imp.at)}) and declared again (line ${lineOf(text, stmt.start)})`,
        );
      }
    }
  }
  return found;
}

function selfTest() {
  const cases = [
    ["const.ts", "const a = 1;\nlet a = 2;\n", 1],
    ["import-list.ts", 'import { a, b, a } from "./m";\n', 1],
    ["two-imports.ts", 'import { a } from "./m";\nimport { a } from "./n";\n', 1],
    ["import-const.ts", 'import { paneSends } from "./m";\nexport const paneSends = {};\n', 1],
    ["import-fn.tsx", 'import { f } from "./m";\nfunction f() {}\n', 1],
    ["import-type.ts", 'import type { T } from "./m";\ntype T = string;\n', 1],
    ["import-inline-type.ts", 'import { type T } from "./m";\ninterface T {}\n', 1],
    ["import-class.ts", 'import { C } from "./m";\nexport class C {}\n', 1],
    ["type-beside-component.tsx", 'import type { Row } from "./m";\nexport function Row() { return null; }\n', 0],
    ["const-fn.ts", "const c = 1;\nfunction c() {}\n", 1],
    ["renamed.ts", 'import { a as b } from "./m";\nconst a = 1;\n', 0],
    [
      "legal.ts",
      'import D, { d } from "./m";\nfunction f(): void;\nfunction f(x?: number) {}\nnamespace N {}\nnamespace N {}\n' +
        "interface I {}\ninterface I {}\nenum E { A }\nenum E { B = 2 }\nconst x = 1;\n{ const x = 2; }\nexport { f };\n",
      0,
    ],
    ["fixture.ts", 'import { a } from "./m";\nconst f = `\nimport { a } from "./n";\n`;\n', 0],
    ["declare.ts", 'import { g } from "./m";\ndeclare global { const g: number; }\n', 0],
  ];
  const bad = [];
  for (const [name, text, want] of cases) {
    const got = duplicates(name, text);
    if (got.length !== want) bad.push(`${name}: want ${want} finding(s), got ${JSON.stringify(got)}`);
  }
  if (bad.length) {
    console.error("self-test failed:\n  " + bad.join("\n  "));
    return 1;
  }
  console.log(`ok: self-test (${cases.length} cases)`);
  return 0;
}

function* walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) yield* walk(join(dir, entry.name));
    } else if (SOURCE.test(entry.name) && !entry.name.endsWith(".d.ts")) {
      yield join(dir, entry.name);
    }
  }
}

async function main(argv) {
  if (argv.includes("--self-test")) return selfTest();
  if (selfTest() !== 0) return 1;
  const dirs = argv.length ? argv : ["src"];
  const paths = dirs.flatMap((dir) => {
    const root = resolve(HERE, dir);
    return statSync(root).isDirectory() ? [...walk(root)] : [root];
  });
  // Turning oxc's AST into JS objects is most of the cost (~5 s on one thread for src), so slices of the
  // files go to worker threads, one per core.
  const count = Math.max(1, Math.min(availableParallelism(), 16, Math.ceil(paths.length / 200)));
  const slices = Array.from({ length: count }, (_, i) => paths.filter((_, j) => j % count === i));
  const results = await Promise.all(
    slices.map(
      (slice) =>
        new Promise((done, fail) => {
          const worker = new Worker(fileURLToPath(import.meta.url), { workerData: slice });
          worker.once("message", done);
          worker.once("error", fail);
        }),
    ),
  );
  const bad = results.flat();
  const files = paths.length;
  bad.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  if (bad.length) {
    console.error("a module binds one name twice (the web build fails on it, or tsc does):\n  " + bad.join("\n  "));
    return 1;
  }
  console.log(`ok: no module binds one name twice (${files} files)`);
  return 0;
}

function readSlice(paths) {
  const bad = [];
  for (const path of paths) {
    for (const finding of duplicates(path, readFileSync(path, "utf8"))) bad.push(`${relative(HERE, path)}: ${finding}`);
  }
  return bad;
}

if (!isMainThread) {
  parentPort.postMessage(readSlice(workerData));
} else if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
