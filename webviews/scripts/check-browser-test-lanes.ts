import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import ts from "typescript";
import { fileURLToPath } from "node:url";

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
  if (/\bwarm(?:Vite|Dev)Server\(/.test(text)) return [];
  return [
    `${path.relative(root, file)}: starts a Vite dev server without warming it; call ${inProcess ? "warmViteServer(vite, page)" : "warmDevServer(base, page)"} from ./support/warmDevServer once it listens`,
  ];
}

if (import.meta.main) {
  const errors: string[] = [];
  function scan(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(file);
      else if (/[._](?:test|spec)\.[cm]?[jt]sx?$/.test(entry.name)) {
        const text = readFileSync(file, "utf8");
        errors.push(...checkBrowserLaneSource(file, text), ...checkDevServerWarmSource(file, text));
      }
    }
  }
  scan(path.join(root, "test"));
  scan(path.join(root, "src"));
  for (const error of errors) console.error(error);
  if (errors.length) process.exitCode = 1;
  else console.log("Browser test lane imports checked.");
}
