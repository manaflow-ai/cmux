import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import ts from "typescript";
import { fileURLToPath } from "node:url";
import { checkFrameReadsSource } from "./check-frame-reads";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "test/support/requireBrowserLane");
const browserModule = /^(?:@playwright\/test|playwright(?:-core|-chromium|-webkit|-firefox)?)(?:\/|$)/;

/** Parse imports without loading any test module (including its module-level engine probes). */
export function checkBrowserLaneSource(file: string, text: string): string[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  let importsBrowser = false;
  let guardBinding: string | undefined;
  function visit(node: ts.Node) {
    let specifier: ts.Node | undefined;
    if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) specifier = node.moduleSpecifier;
    if (
      ts.isCallExpression(node) &&
      (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
        (ts.isIdentifier(node.expression) && node.expression.text === "require"))
    )
      specifier = node.arguments[0];
    if (ts.isExternalModuleReference(node)) specifier = node.expression;
    if (specifier && ts.isStringLiteralLike(specifier) && browserModule.test(specifier.text)) importsBrowser = true;
    ts.forEachChild(node, visit);
  }
  visit(source);
  if (!importsBrowser) return [];

  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
    const resolved = path.resolve(path.dirname(file), statement.moduleSpecifier.text).replace(/\.[cm]?[jt]s$/, "");
    if (resolved !== helper || statement.importClause?.isTypeOnly) continue;
    const bindings = statement.importClause?.namedBindings;
    if (bindings && ts.isNamedImports(bindings)) {
      for (const binding of bindings.elements) {
        if (!binding.isTypeOnly && (binding.propertyName ?? binding.name).text === "requireBrowserLane") {
          guardBinding = binding.name.text;
        }
      }
    }
  }
  const executable = source.statements.filter(
    (statement) =>
      !ts.isImportDeclaration(statement) &&
      !ts.isInterfaceDeclaration(statement) &&
      !ts.isTypeAliasDeclaration(statement),
  );
  const statement = executable[0];
  const call =
    statement && ts.isExpressionStatement(statement) && ts.isAwaitExpression(statement.expression)
      ? statement.expression.expression
      : undefined;
  if (
    guardBinding &&
    executable.length === 1 &&
    call &&
    ts.isCallExpression(call) &&
    ts.isIdentifier(call.expression) &&
    call.expression.text === guardBinding &&
    call.arguments.length === 2
  ) {
    const [name, register] = call.arguments;
    // A literal name and an inline callback cannot run setup while evaluating the arguments.
    if (
      ts.isStringLiteralLike(name) &&
      (ts.isArrowFunction(register) || ts.isFunctionExpression(register)) &&
      register.parameters.length === 0 &&
      ts.isBlock(register.body)
    )
      return [];
  }
  return [
    `${path.relative(root, file)}: browser imports require one top-level await requireBrowserLane("name", async () => { ... }); put all setup, probes, hooks and tests inside it`,
  ];
}

/**
 * A test that starts a Vite dev server warms it (test/support/warmDevServer.ts) before a browser
 * loads a page: Vite transforms each module on its first request, and a cold first load ran past
 * the 30 s navigation timeout on a busy CI runner (#20697, #20681).
 */
export function checkDevServerWarmSource(file: string, text: string): string[] {
  const inProcess = /\bawait\s+vite\.listen\(\)/.test(text);
  const spawned = text.includes("node_modules/.bin/vp") && /\[\s*"dev",/.test(text);
  if (!inProcess && !spawned) return [];
  // A server no browser loads (dev-server-stop: starting and stopping it) has nothing to warm.
  if (!/from "playwright"/.test(text)) return [];
  if (/\bwarm(?:Vite|Dev)Server\(|\bwarmGalleryFrame\(/.test(text)) return [];
  return [
    `${path.relative(root, file)}: starts a Vite dev server without warming it; call ${inProcess ? "warmViteServer(vite, page)" : "warmDevServer(base, page)"} from ./support/warmDevServer (or warmGalleryFrame from ./support/galleryFrame) once it listens`,
  ];
}

/**
 * Browser tests that still open a frame for every entry, each with why; remove a line when its test
 * moves to galleryFrame. Narrowed in batches by area; the files other lanes' open PRs change wait
 * for those PRs.
 */
export const EVERY_ENTRY_PENDING = new Map<string, string>([
  // Files other lanes' open PRs change.
  ["test/transcript-thought.test.ts", "#23084 (thought-rows) changes this file"],
]);

/**
 * A browser test opens a gallery frame for its own entry alone (test/support/galleryFrame.ts):
 * `/gallery/frame.html` without `entryPath` loads every gallery entry first, about 2,300 modules a
 * test file, and timed tests out on a busy CI runner (#23080). A test that needs the whole registry
 * says why in a `// gallery-frame-every-entry: <reason>` comment.
 */
export function checkGalleryFrameSource(file: string, text: string): string[] {
  const name = path.relative(root, file);
  const pending = EVERY_ENTRY_PENDING.has(name);
  if (!/^import\b[^;]*\bfrom "playwright";/m.test(text))
    return pending ? [`${name}: opens no browser now; remove it from EVERY_ENTRY_PENDING`] : [];
  if (/^\s*\/\/ gallery-frame-every-entry: \S/m.test(text))
    return pending ? [`${name}: says why it opens every entry; remove it from EVERY_ENTRY_PENDING`] : [];
  const errors = text
    .split("\n")
    .flatMap((line, index) =>
      /frame\.html/.test(line) && !/entryPath/.test(line)
        ? [
            `${name}:${index + 1}: opens a gallery frame without entryPath, so it loads every gallery entry; use galleryFrame(entry, params) and warmGalleryFrame(vite, entry) from ./support/galleryFrame, or say why it needs them all in a "// gallery-frame-every-entry: <reason>" comment`,
          ]
        : [],
    );
  if (!pending) return errors;
  return errors.length ? [] : [`${name}: opens its frames narrowed now; remove it from EVERY_ENTRY_PENDING`];
}

if (import.meta.main) {
  const errors: string[] = [];
  function scan(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(file);
      else if (/[._](?:test|spec)\.[cm]?[jt]sx?$/.test(entry.name)) {
        const text = readFileSync(file, "utf8");
        errors.push(
          ...checkBrowserLaneSource(file, text),
          ...checkDevServerWarmSource(file, text),
          ...checkGalleryFrameSource(file, text),
          ...checkFrameReadsSource(file, text),
        );
      }
    }
  }
  scan(path.join(root, "test"));
  scan(path.join(root, "src"));
  for (const name of EVERY_ENTRY_PENDING.keys())
    if (!existsSync(path.join(root, name))) errors.push(`${name}: is gone; remove it from EVERY_ENTRY_PENDING`);
  for (const error of errors) console.error(error);
  if (errors.length) process.exitCode = 1;
  else console.log("Browser test lane imports checked.");
}
