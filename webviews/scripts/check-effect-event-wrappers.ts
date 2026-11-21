// `useEffectEvent` only works in a plain function component's fiber. React 19.2.3 hands an effect
// event its new render's function in commitBeforeMutationEffects, for `case 0:` (FunctionComponent)
// only; it has `case 11: case 15: break;` (react-dom-client.development.js 13875-13892,
// production 8926-8943). So in a `forwardRef` component (tag 11) or a plain `React.memo(fn)`
// (tag 15: updateMemoComponent makes one only for a function with no defaultProps and no compare,
// development 9751-9760), the event keeps its first render's function forever. `memo(fn, compare)`
// renders `fn` in a child fiber of tag 0, so its events refresh; `memo(forwardRef(fn))` renders `fn`
// in a tag-11 fiber. test/effect-event-wrappers-react.test.tsx pins that behaviour.
//
// This check names each `useEffectEvent` call in src whose component is one of those, and each call
// such a component makes to a same-file hook that uses `useEffectEvent` (a hook in another file is
// not followed). An event every use of which is a call directly in an effect whose deps are literally `[]`
// passes: that effect runs once, after the first render, so the first function is the right one. A
// `// effect-event: mount-only` comment on the call's line or the line above passes it too.
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const effectHooks = new Set(["useEffect", "useLayoutEffect", "useInsertionEffect"]);
const marker = /\/\/\s*effect-event:\s*mount-only\b/;

type Fn = ts.FunctionDeclaration | ts.FunctionExpression | ts.ArrowFunction | ts.MethodDeclaration;
type Wrapper = "memo" | "forwardRef";

const isFn = (node: ts.Node): node is Fn =>
  ts.isFunctionDeclaration(node) ||
  ts.isFunctionExpression(node) ||
  ts.isArrowFunction(node) ||
  ts.isMethodDeclaration(node);

function enclosingFn(node: ts.Node): Fn | undefined {
  for (let at = node.parent; at; at = at.parent) if (isFn(at)) return at;
  return undefined;
}

/** The node an expression stands for once parentheses, `as` and `satisfies` are looked through. */
function outer(node: ts.Node): ts.Node {
  let at = node;
  while (
    at.parent &&
    (ts.isParenthesizedExpression(at.parent) ||
      ts.isAsExpression(at.parent) ||
      ts.isSatisfiesExpression(at.parent) ||
      ts.isNonNullExpression(at.parent))
  )
    at = at.parent;
  return at;
}

function inner(node: ts.Expression): ts.Expression {
  let at = node;
  while (
    ts.isParenthesizedExpression(at) ||
    ts.isAsExpression(at) ||
    ts.isSatisfiesExpression(at) ||
    ts.isNonNullExpression(at)
  )
    at = at.expression;
  return at;
}

export function checkEffectEventWrappersSource(file: string, text: string): string[] {
  if (!text.includes("useEffectEvent")) return [];
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const lines = text.split("\n");

  // React's own names in this file, aliases included.
  const local = new Map<string, string>([
    ["useEffectEvent", "useEffectEvent"],
    ["memo", "memo"],
    ["forwardRef", "forwardRef"],
  ]);
  const namespaces = new Set(["React"]);
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
    if (statement.moduleSpecifier.text !== "react") continue;
    const clause = statement.importClause;
    if (clause?.name) namespaces.add(clause.name.text);
    const bindings = clause?.namedBindings;
    if (bindings && ts.isNamespaceImport(bindings)) namespaces.add(bindings.name.text);
    if (bindings && ts.isNamedImports(bindings))
      for (const binding of bindings.elements)
        local.set(binding.name.text, (binding.propertyName ?? binding.name).text);
  }
  const reactName = (callee: ts.Expression): string | undefined => {
    const at = inner(callee);
    if (ts.isIdentifier(at)) return local.get(at.text);
    if (ts.isPropertyAccessExpression(at) && ts.isIdentifier(at.expression) && namespaces.has(at.expression.text))
      return at.name.text;
    return undefined;
  };
  const calleeName = (call: ts.CallExpression): string | undefined => {
    const at = inner(call.expression);
    if (ts.isIdentifier(at)) return at.text;
    if (ts.isPropertyAccessExpression(at)) return at.name.text;
    return undefined;
  };

  const events: ts.CallExpression[] = [];
  const wraps: ts.CallExpression[] = [];
  const calls: ts.CallExpression[] = [];
  const fns: Fn[] = [];
  function visit(node: ts.Node) {
    if (isFn(node)) fns.push(node);
    if (ts.isCallExpression(node)) {
      calls.push(node);
      const name = reactName(node.expression);
      if (name === "useEffectEvent") events.push(node);
      if (name === "memo" || name === "forwardRef") wraps.push(node);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  if (!events.length) return [];

  /** The name a function is known by in this file: its own, or the const it (or its wrapper) is bound to. */
  function nameOf(fn: Fn): string | undefined {
    if (fn.name && ts.isIdentifier(fn.name)) return fn.name.text;
    let at = outer(fn);
    while (ts.isCallExpression(at.parent) && wraps.includes(at.parent)) at = outer(at.parent);
    return ts.isVariableDeclaration(at.parent) && ts.isIdentifier(at.parent.name) ? at.parent.name.text : undefined;
  }
  /** The fiber-breaking wrapper a function is rendered by: written around it, or around its name in this file. */
  function wrapperOf(fn: Fn): Wrapper | undefined {
    const name = fn.name && ts.isIdentifier(fn.name) ? fn.name.text : undefined;
    const bound = outer(fn).parent;
    const constName = ts.isVariableDeclaration(bound) && ts.isIdentifier(bound.name) ? bound.name.text : undefined;
    let found: Wrapper | undefined;
    for (const call of wraps) {
      const first = call.arguments[0];
      if (!first) continue;
      const arg = inner(first);
      const direct = arg === fn;
      const named = ts.isIdentifier(arg) && (arg.text === name || arg.text === constName);
      if (!direct && !named) continue;
      const kind = reactName(call.expression);
      if (kind === "forwardRef") return "forwardRef";
      if (kind === "memo" && call.arguments.length < 2) found = "memo";
    }
    return found;
  }

  /** Every use of the event is directly in an effect callback with `[]` deps, or the line says so. */
  function mountOnly(event: ts.CallExpression): boolean {
    const line = source.getLineAndCharacterOfPosition(event.getStart(source)).line;
    if (marker.test(lines[line] ?? "") || (line > 0 && marker.test(lines[line - 1] ?? ""))) return true;
    const declaration = outer(event).parent;
    const owner = enclosingFn(event);
    if (!owner || !ts.isVariableDeclaration(declaration) || !ts.isIdentifier(declaration.name)) return false;
    const declared = declaration.name;
    const binding = declared.text;
    let ok = true;
    function scan(node: ts.Node) {
      if (!ok) return;
      if (
        ts.isIdentifier(node) &&
        node.text === binding &&
        node !== declared &&
        !(ts.isPropertyAccessExpression(node.parent) && node.parent.name === node) &&
        !(ts.isPropertyAssignment(node.parent) && node.parent.name === node)
      ) {
        // Called right there: handed on as a value (a listener), it would run later, stale.
        const use = outer(node).parent;
        const called = ts.isCallExpression(use) && inner(use.expression) === node;
        const callback = enclosingFn(node);
        const effect = callback && outer(callback).parent;
        ok =
          called &&
          !!callback &&
          !!effect &&
          ts.isCallExpression(effect) &&
          effectHooks.has(calleeName(effect) ?? "") &&
          inner(effect.arguments[0]!) === callback &&
          effect.arguments.length === 2 &&
          ts.isArrayLiteralExpression(inner(effect.arguments[1]!)) &&
          (inner(effect.arguments[1]!) as ts.ArrayLiteralExpression).elements.length === 0;
        return;
      }
      ts.forEachChild(node, scan);
    }
    if (owner.body) scan(owner.body);
    return ok;
  }

  const live = events.filter((event) => !mountOnly(event));
  // Same-file hooks that use an effect event, directly or through another such hook.
  const eventHooks = new Map<string, Fn>();
  const isHook = (name: string | undefined): name is string => !!name && /^use[A-Z0-9]/.test(name);
  for (const event of live) {
    const fn = enclosingFn(event);
    const name = fn && nameOf(fn);
    if (fn && isHook(name)) eventHooks.set(name, fn);
  }
  for (let grew = true; grew;) {
    grew = false;
    for (const call of calls) {
      const callee = inner(call.expression);
      if (!ts.isIdentifier(callee) || !eventHooks.has(callee.text)) continue;
      const fn = enclosingFn(call);
      const name = fn && nameOf(fn);
      if (fn && isHook(name) && !eventHooks.has(name)) {
        eventHooks.set(name, fn);
        grew = true;
      }
    }
  }

  const rel = path.isAbsolute(file) ? path.relative(root, file) : file;
  const where = (node: ts.Node) => `${rel}:${source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1}`;
  const what = (fn: Fn, kind: Wrapper) =>
    `${nameOf(fn) ?? "an anonymous component"}, ${kind === "memo" ? "a React.memo component with no comparator (fiber tag 15)" : "a forwardRef component (fiber tag 11)"}`;
  const fix =
    "React 19.2.3 hands an effect event its new render's function only in a plain function component's fiber (react-dom commitBeforeMutationEffects: `case 11: case 15: break`), so here it keeps its first render's function; use useCommittedEvent (src/agent-session/acpmux/useCommittedEvent.ts) instead, or call the event only directly in an effect with `[]` deps (or mark it `// effect-event: mount-only`)";
  const errors: string[] = [];
  for (const event of live) {
    const fn = enclosingFn(event);
    const kind = fn && wrapperOf(fn);
    if (fn && kind) errors.push(`${where(event)}: useEffectEvent in ${what(fn, kind)}: ${fix}`);
  }
  for (const fn of fns) {
    const kind = wrapperOf(fn);
    if (!kind) continue;
    for (const call of calls) {
      const callee = inner(call.expression);
      if (ts.isIdentifier(callee) && eventHooks.has(callee.text) && enclosingFn(call) === fn)
        errors.push(`${where(call)}: ${callee.text} uses useEffectEvent and is called by ${what(fn, kind)}: ${fix}`);
    }
  }
  return errors;
}

if (import.meta.main) {
  const errors: string[] = [];
  function scan(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(file);
      else if (/\.[cm]?[jt]sx?$/.test(entry.name) && !entry.name.endsWith(".d.ts"))
        errors.push(...checkEffectEventWrappersSource(file, readFileSync(file, "utf8")));
    }
  }
  scan(path.join(root, "src"));
  for (const error of errors) console.error(error);
  if (errors.length) process.exitCode = 1;
  else console.log("Effect events checked: none in a React.memo or forwardRef component.");
}
