import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import ts from "typescript";
import { fileURLToPath } from "node:url";
import { compareToBaseline, componentName, productSources, readBaseline, writeBaseline } from "./check-whole-list-rows";

/**
 * Unregistered-list ratchet: a JSX list loop in src/ is a list the list contract measures, a list with a
 * named hard cap, or one from before the rule. A loop over the person's data that draws every entry
 * costs more with every session, message or file they add, and the list contract
 * (test/support/listContract.ts) is what keeps a list's cost flat from 1,000 rows to 10,000; this check
 * keeps a new list from skipping it.
 *
 * A list loop is a `.map(` or `.flatMap(` whose callback returns JSX, an `Array.from(x, fn)` whose `fn`
 * does, or a for, for-of, for-in or while loop that pushes JSX into an array, in a .tsx file under src/
 * (galleries, prototypes, tests, fixtures and generated files are skipped, as in check-whole-list-rows).
 * One is fine when:
 *   its collection is constant: an array literal, a const bound to one (`as const`, `Object.freeze` and
 *   `satisfies` too), the keys, values or entries of a const object or an enum, `Array.from({ length: K })`,
 *   `Array(K)`, `.slice(0, K)` or `.slice(-K)`, or a for loop up to K, with K a number or a const number
 *   <= 100; a filter, sort or map of a constant collection is constant too. `React.Children.map` is the
 *   caller's own JSX and is not a list.
 *   it sits in the component a list fixture registers (test/list-contract/<name>.fixture.tsx, whose
 *   `source: "path#Export"` names a function in webviews/src), so the contract measures it.
 *   it has a `// list-cap: NAME` (or `{/* list-cap: NAME *\/}`) comment on its first line or the comment
 *   lines just above it, NAME a const number <= 100 in the file or its direct import. The comment is the
 *   claim that the collection never holds more than NAME entries; a NAME over 100, or one that does not
 *   resolve, always fails.
 *
 * Files from before the rule have a count in list-contract-baseline.tsv, which moves only down, as
 * whole-list-rows-baseline.tsv does: a file fails above its row, and below it until the row is lowered
 * (`--update-baseline`), which refuses to raise a row.
 */

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const baselinePath = path.join(root, "scripts/list-contract-baseline.tsv");
const fixtureDirectory = path.join(root, "test/list-contract");
/** The largest a named cap may be: past it a list is long enough that the contract should measure it. */
export const MAX_CAP = 100;
const CAP_MARKER = /(?:\/\/|\/\*)\s*list-cap:\s*([A-Za-z_$][\w$]*)/;
const COMMENT_LINE = /^\s*(?:\/\/|\{?\/\*|\*)/;
const FIXTURE_SOURCE = /\bsource:\s*["'`]([^"'`#\s]+)#([A-Za-z_$][\w$]*)["'`]/g;
/** Array methods whose result is no longer than their receiver. */
const SAME_OR_SHORTER = new Set([
  "filter",
  "sort",
  "toSorted",
  "reverse",
  "toReversed",
  "map",
  "flat",
  "keys",
  "values",
  "entries",
  "fill",
]);
/** How deep a name or helper function is followed before the check gives up and calls it unknown. */
const DEPTH = 6;

/** Components each source file registers with the list contract, by path relative to webviews/. */
export function readRegistry(directory = fixtureDirectory): Map<string, Set<string>> {
  const registry = new Map<string, Set<string>>();
  if (!existsSync(directory)) return registry;
  for (const name of readdirSync(directory)) {
    if (!name.endsWith(".fixture.tsx")) continue;
    registerFixture(readFileSync(path.join(directory, name), "utf8"), registry);
  }
  return registry;
}

/** Adds a fixture's `source: "path#Export"` entries (paths under webviews/src) to a registry. */
export function registerFixture(text: string, registry: Map<string, Set<string>>) {
  for (const [, file, name] of text.matchAll(FIXTURE_SOURCE)) {
    const key = path.posix.join("src", file!);
    if (!registry.has(key)) registry.set(key, new Set());
    registry.get(key)!.add(name!);
  }
}

type Module = { file: string; source: ts.SourceFile };
type Reader = (file: string) => string | undefined;

const readFromDisk: Reader = (file) => (existsSync(file) ? readFileSync(file, "utf8") : undefined);

function unwrap(node: ts.Expression): ts.Expression {
  while (
    ts.isParenthesizedExpression(node) ||
    ts.isAsExpression(node) ||
    ts.isSatisfiesExpression(node) ||
    ts.isNonNullExpression(node) ||
    ts.isTypeAssertionExpression(node)
  )
    node = node.expression;
  return node;
}

/** A call's callee as `name` or `object.name`: `Array.from`, `Object.keys`, `useMemo`. */
function calleeName(node: ts.CallExpression | ts.NewExpression): string {
  const callee = node.expression;
  if (ts.isIdentifier(callee)) return callee.text;
  if (ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression))
    return `${callee.expression.text}.${callee.name.text}`;
  return "";
}

/**
 * Resolves names in one file: its own top-level declarations, the consts and functions of the blocks a
 * node sits in, and a named import from a relative path (one hop, the direct import).
 */
class Resolver {
  private modules = new Map<string, Module | undefined>();
  constructor(private read: Reader) {}

  module(file: string, text?: string): Module | undefined {
    if (!this.modules.has(file)) {
      const body = text ?? this.read(file);
      this.modules.set(
        file,
        body === undefined
          ? undefined
          : {
              file,
              source: ts.createSourceFile(
                file,
                body,
                ts.ScriptTarget.Latest,
                true,
                file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
              ),
            },
      );
    }
    return this.modules.get(file);
  }

  /** The file a relative import names, trying the extensions TypeScript would. */
  private importTarget(from: string, specifier: string): string | undefined {
    if (!specifier.startsWith(".")) return undefined;
    const base = path.resolve(path.dirname(from), specifier);
    for (const candidate of [
      base,
      `${base}.ts`,
      `${base}.tsx`,
      path.join(base, "index.ts"),
      path.join(base, "index.tsx"),
    ])
      if (/\.tsx?$/.test(candidate) && this.read(candidate) !== undefined) return candidate;
    return undefined;
  }

  /** The declaration `name` means at `at` in `module`, and the module it is in. */
  resolve(module: Module, at: ts.Node, name: string, imports = true): { module: Module; node: ts.Node } | undefined {
    for (let scope: ts.Node | undefined = at; scope; scope = scope.parent) {
      if (ts.isFunctionLike(scope) && scope !== at)
        for (const parameter of scope.parameters)
          if (ts.isIdentifier(parameter.name) && parameter.name.text === name) return undefined;
      if (!ts.isBlock(scope) && !ts.isSourceFile(scope) && !ts.isModuleBlock(scope)) continue;
      for (const statement of scope.statements) {
        const found = declares(statement, name);
        if (found) return { module, node: found };
        if (imports && ts.isSourceFile(scope) && ts.isImportDeclaration(statement)) {
          const imported = this.imported(module, statement, name);
          if (imported) return imported;
        }
      }
    }
    return undefined;
  }

  private imported(module: Module, statement: ts.ImportDeclaration, name: string) {
    const bindings = statement.importClause?.namedBindings;
    if (!bindings || !ts.isNamedImports(bindings) || !ts.isStringLiteral(statement.moduleSpecifier)) return undefined;
    const element = bindings.elements.find((e) => e.name.text === name);
    if (!element) return undefined;
    const target = this.importTarget(module.file, statement.moduleSpecifier.text);
    const other = target ? this.module(target) : undefined;
    // The direct import's own top level only: a re-export is not followed.
    return other ? this.resolve(other, other.source, (element.propertyName ?? element.name).text, false) : undefined;
  }

  /** The value of a numeric expression, following const names; undefined when it is not one. */
  number(module: Module, node: ts.Expression, depth = 0): number | undefined {
    node = unwrap(node);
    if (depth > DEPTH) return undefined;
    if (ts.isNumericLiteral(node)) return Number(node.text.replace(/_/g, ""));
    if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.MinusToken) {
      const value = this.number(module, node.operand, depth + 1);
      return value === undefined ? undefined : -value;
    }
    if (ts.isBinaryExpression(node)) {
      const left = this.number(module, node.left, depth + 1);
      const right = this.number(module, node.right, depth + 1);
      if (left === undefined || right === undefined) return undefined;
      switch (node.operatorToken.kind) {
        case ts.SyntaxKind.PlusToken:
          return left + right;
        case ts.SyntaxKind.MinusToken:
          return left - right;
        case ts.SyntaxKind.AsteriskToken:
          return left * right;
        case ts.SyntaxKind.SlashToken:
          return left / right;
        default:
          return undefined;
      }
    }
    if (ts.isIdentifier(node)) {
      const found = this.resolve(module, node, node.text);
      return found && ts.isVariableDeclaration(found.node) && found.node.initializer
        ? this.number(found.module, found.node.initializer, depth + 1)
        : undefined;
    }
    return undefined;
  }

  /** The object literal or enum an expression names, following const names and `Object.freeze`. */
  object(module: Module, node: ts.Expression, depth: number): { module: Module; node: ts.Node } | undefined {
    node = unwrap(node);
    if (depth > DEPTH) return undefined;
    if (ts.isObjectLiteralExpression(node)) return { module, node };
    if (ts.isCallExpression(node) && calleeName(node) === "Object.freeze" && node.arguments[0])
      return this.object(module, node.arguments[0], depth + 1);
    if (ts.isIdentifier(node)) {
      const found = this.resolve(module, node, node.text);
      if (!found) return undefined;
      if (ts.isEnumDeclaration(found.node)) return found;
      if (ts.isVariableDeclaration(found.node) && found.node.initializer)
        return this.object(found.module, found.node.initializer, depth + 1);
    }
    if (ts.isPropertyAccessExpression(node)) {
      const value = this.property(module, node, depth);
      return value ? this.object(value.module, value.node, depth + 1) : undefined;
    }
    return undefined;
  }

  /** `A.b` where A is a const object literal: b's initializer. */
  private property(module: Module, node: ts.PropertyAccessExpression, depth: number) {
    const owner = this.object(module, node.expression, depth + 1);
    if (!owner || !ts.isObjectLiteralExpression(owner.node)) return undefined;
    for (const member of owner.node.properties)
      if (ts.isPropertyAssignment(member) && member.name.getText(owner.module.source) === node.name.text)
        return { module: owner.module, node: member.initializer };
    return undefined;
  }

  /** Whether an expression is a collection of at most MAX_CAP entries the person's data cannot grow. */
  constant(module: Module, node: ts.Expression, depth = 0): boolean {
    node = unwrap(node);
    if (depth > DEPTH) return false;
    const small = (expression: ts.Expression | undefined) => {
      const value = expression ? this.number(module, expression) : undefined;
      return value !== undefined && Math.abs(value) <= MAX_CAP;
    };
    if (ts.isArrayLiteralExpression(node))
      return node.elements.every((e) => !ts.isSpreadElement(e) || this.constant(module, e.expression, depth + 1));
    if (ts.isIdentifier(node)) {
      const found = this.resolve(module, node, node.text);
      if (!found) return false;
      if (ts.isEnumDeclaration(found.node)) return true;
      if (!ts.isVariableDeclaration(found.node) || !found.node.initializer) return false;
      if (!(ts.getCombinedNodeFlags(found.node) & ts.NodeFlags.Const)) return false;
      return this.constant(found.module, found.node.initializer, depth + 1);
    }
    if (ts.isPropertyAccessExpression(node)) {
      const value = this.property(module, node, depth);
      return !!value && this.constant(value.module, value.node as ts.Expression, depth + 1);
    }
    // `wide ? [...KINDS, extra] : KINDS`, `chosen ?? DEFAULTS`: constant when every branch is.
    if (ts.isConditionalExpression(node))
      return this.constant(module, node.whenTrue, depth + 1) && this.constant(module, node.whenFalse, depth + 1);
    if (
      ts.isBinaryExpression(node) &&
      (node.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken ||
        node.operatorToken.kind === ts.SyntaxKind.BarBarToken)
    )
      return this.constant(module, node.left, depth + 1) && this.constant(module, node.right, depth + 1);
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression)) {
      // A helper in the file (or its direct import) whose every return is a constant collection.
      const found = this.resolve(module, node.expression, node.expression.text);
      const fn =
        found && ts.isFunctionDeclaration(found.node)
          ? found.node
          : found && ts.isVariableDeclaration(found.node) && found.node.initializer
            ? unwrap(found.node.initializer)
            : undefined;
      if (fn && (ts.isFunctionDeclaration(fn) || ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)) && found)
        return this.everyReturn(fn, (value) => this.constant(found.module, value, depth + 1));
    }
    if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
      const name = calleeName(node);
      const args = node.arguments ?? ts.factory.createNodeArray();
      if (name === "Object.keys" || name === "Object.values" || name === "Object.entries")
        return !!args[0] && (!!this.object(module, args[0], depth + 1) || this.constant(module, args[0], depth + 1));
      if (name === "Object.freeze") return !!args[0] && this.constant(module, args[0], depth + 1);
      if (name === "Array") return args.length === 1 && small(args[0]);
      if (name === "Array.from") {
        const first = args[0] && unwrap(args[0]);
        if (first && ts.isObjectLiteralExpression(first)) {
          const length = first.properties.find(
            (p): p is ts.PropertyAssignment => ts.isPropertyAssignment(p) && p.name.getText(module.source) === "length",
          );
          return small(length?.initializer);
        }
        return !!first && this.constant(module, first, depth + 1);
      }
      // A memo of a constant expression is constant: `useMemo(() => TABS.filter(…), [])`.
      if (name === "useMemo" || name === "React.useMemo") {
        const factory = args[0] && unwrap(args[0]);
        return (
          !!factory &&
          ts.isArrowFunction(factory) &&
          !ts.isBlock(factory.body) &&
          this.constant(module, factory.body, depth + 1)
        );
      }
      if (ts.isPropertyAccessExpression(node.expression)) {
        const method = node.expression.name.text;
        const receiver = node.expression.expression;
        if (method === "slice") {
          const [start, end] = args;
          const from = start ? this.number(module, start) : 0;
          const to = end ? this.number(module, end) : undefined;
          // `.slice(0, K)`, `.slice(-K)`.
          if (from !== undefined && to !== undefined && to - from <= MAX_CAP && from >= 0) return true;
          if (from !== undefined && from < 0 && from >= -MAX_CAP && to === undefined) return true;
          return this.constant(module, receiver, depth + 1);
        }
        if (method === "concat")
          return this.constant(module, receiver, depth + 1) && args.every((a) => this.constant(module, a, depth + 1));
        if (SAME_OR_SHORTER.has(method)) return this.constant(module, receiver, depth + 1);
      }
    }
    return false;
  }

  /** Whether a callback (a function, or the name of one in the file) returns JSX. */
  returnsJsx(module: Module, node: ts.Expression | undefined, depth = 0): boolean {
    if (!node || depth > DEPTH) return false;
    node = unwrap(node);
    if (ts.isIdentifier(node)) {
      const found = this.resolve(module, node, node.text);
      // A row renderer the caller passes in (`render`, `renderRow`) is a parameter, so it does not resolve.
      if (!found) return /^render(?:[A-Z_]\w*)?$/.test(node.text);
      if (ts.isFunctionDeclaration(found.node)) return this.bodyReturnsJsx(found.module, found.node, depth + 1);
      if (ts.isVariableDeclaration(found.node) && found.node.initializer)
        return this.returnsJsx(found.module, found.node.initializer, depth + 1);
      return false;
    }
    if (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) return this.bodyReturnsJsx(module, node, depth);
    return false;
  }

  /** Whether a function returns something and every value it returns passes `test`. */
  private everyReturn(fn: ts.FunctionLikeDeclaration, test: (value: ts.Expression) => boolean): boolean {
    if (!fn.body) return false;
    if (!ts.isBlock(fn.body)) return test(fn.body);
    let any = false;
    let all = true;
    const visit = (node: ts.Node) => {
      if (!all || ts.isFunctionLike(node)) return;
      if (ts.isReturnStatement(node)) {
        any = true;
        if (!node.expression || !test(node.expression)) all = false;
      } else ts.forEachChild(node, visit);
    };
    ts.forEachChild(fn.body, visit);
    return any && all;
  }

  private bodyReturnsJsx(module: Module, fn: ts.FunctionLikeDeclaration, depth: number): boolean {
    if (!fn.body) return false;
    if (!ts.isBlock(fn.body)) return this.jsx(module, fn.body, depth);
    let found = false;
    const visit = (node: ts.Node) => {
      if (found || ts.isFunctionLike(node)) return;
      if (ts.isReturnStatement(node) && node.expression && this.jsx(module, node.expression, depth)) found = true;
      else ts.forEachChild(node, visit);
    };
    ts.forEachChild(fn.body, visit);
    return found;
  }

  /** Whether an expression evaluates to JSX: an element, a branch of one, or a helper in the file that returns one. */
  jsx(module: Module, node: ts.Expression, depth = 0): boolean {
    node = unwrap(node);
    if (depth > DEPTH) return false;
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node) || ts.isJsxFragment(node)) return true;
    if (ts.isConditionalExpression(node))
      return this.jsx(module, node.whenTrue, depth + 1) || this.jsx(module, node.whenFalse, depth + 1);
    if (ts.isBinaryExpression(node)) {
      const kind = node.operatorToken.kind;
      if (
        kind === ts.SyntaxKind.AmpersandAmpersandToken ||
        kind === ts.SyntaxKind.BarBarToken ||
        kind === ts.SyntaxKind.QuestionQuestionToken
      )
        return this.jsx(module, node.left, depth + 1) || this.jsx(module, node.right, depth + 1);
      return false;
    }
    if (ts.isArrayLiteralExpression(node))
      return node.elements.some((e) => this.jsx(module, ts.isSpreadElement(e) ? e.expression : e, depth + 1));
    if (ts.isCallExpression(node)) {
      const name = calleeName(node);
      if (/(?:^|\.)(?:createElement|cloneElement)$/.test(name)) return true;
      if (ts.isPropertyAccessExpression(node.expression) && /^(?:map|flatMap)$/.test(node.expression.name.text))
        return this.returnsJsx(module, node.arguments[0], depth + 1);
      if (ts.isIdentifier(node.expression)) return this.returnsJsx(module, node.expression, depth + 1);
    }
    return false;
  }
}

/** The const or function a statement declares under `name`, if any. */
function declares(statement: ts.Statement, name: string): ts.Node | undefined {
  if (ts.isVariableStatement(statement)) {
    for (const declaration of statement.declarationList.declarations)
      if (ts.isIdentifier(declaration.name) && declaration.name.text === name) return declaration;
    return undefined;
  }
  if (
    (ts.isFunctionDeclaration(statement) || ts.isEnumDeclaration(statement) || ts.isClassDeclaration(statement)) &&
    statement.name?.text === name
  )
    return statement;
  return undefined;
}

/** Whether a loop body (outside any function in it) pushes JSX into an array or assigns JSX into one. */
function pushesJsx(resolver: Resolver, module: Module, body: ts.Node): boolean {
  let found = false;
  const visit = (node: ts.Node) => {
    if (found || ts.isFunctionLike(node)) return;
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      /^(?:push|unshift)$/.test(node.expression.name.text) &&
      node.arguments.some((a) => resolver.jsx(module, ts.isSpreadElement(a) ? a.expression : a))
    )
      found = true;
    else if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isElementAccessExpression(node.left) &&
      resolver.jsx(module, node.right)
    )
      found = true;
    else ts.forEachChild(node, visit);
  };
  visit(body);
  return found;
}

export type ListFindings = {
  /** Each unregistered, uncapped list loop over a non-constant collection, as `file:line`. */
  loops: string[];
  /** Each `list-cap` comment that names no const number, or one over MAX_CAP, as `file:line: why`. */
  badCaps: string[];
};

export type ListOptions = {
  /** Components this file registers with the list contract (readRegistry's entry for it). */
  registered?: ReadonlySet<string>;
  /** Reads an imported file, for a cap or a constant defined there. */
  read?: Reader;
  /** Called with each list loop's `file:line` and what the check made of it, for a spot check. */
  trace?: (at: string, verdict: "constant" | "registered" | "capped" | "unregistered") => void;
};

/** The list loops in one .tsx source that are not constant, registered or capped. */
export function findUnregisteredLists(file: string, text: string, options: ListOptions = {}): ListFindings {
  const resolver = new Resolver(options.read ?? readFromDisk);
  const module = resolver.module(file, text)!;
  const { source } = module;
  const registered = options.registered ?? new Set<string>();
  const lines = text.split("\n");
  const line = (position: number) => source.getLineAndCharacterOfPosition(position).line;
  const name = path.relative(root, file);
  const loops: string[] = [];
  const badCaps: string[] = [];

  // A cap on the loop's own first line, or on the comment lines just above it. Not the whole statement: a
  // `return (…)` with several lists in it needs a cap for each.
  const capAt = (node: ts.Node): { cap: string; at: number } | undefined => {
    const first = line(node.getStart(source));
    const own = CAP_MARKER.exec(lines[first] ?? "");
    if (own) return { cap: own[1]!, at: first };
    for (let at = first - 1; at >= 0 && COMMENT_LINE.test(lines[at] ?? ""); at--) {
      const marker = CAP_MARKER.exec(lines[at] ?? "");
      if (marker) return { cap: marker[1]!, at };
    }
    return undefined;
  };

  const inRegistered = (node: ts.Node) => {
    for (let at = node.parent; at; at = at.parent)
      if (ts.isFunctionLike(at)) {
        const component = componentName(at);
        if (component && registered.has(component)) return true;
      }
    return false;
  };

  const consider = (node: ts.Node, constant: () => boolean) => {
    const at = `${name}:${line(node.getStart(source)) + 1}`;
    if (constant()) return options.trace?.(at, "constant");
    if (inRegistered(node)) return options.trace?.(at, "registered");
    const marker = capAt(node);
    if (marker) {
      options.trace?.(at, "capped");
      const found = resolver.resolve(module, source, marker.cap);
      const value =
        found && ts.isVariableDeclaration(found.node) && found.node.initializer
          ? resolver.number(found.module, found.node.initializer)
          : undefined;
      if (value === undefined)
        badCaps.push(
          `${name}:${marker.at + 1}: list-cap ${marker.cap} is not a const number in this file or its direct import`,
        );
      else if (value > MAX_CAP)
        badCaps.push(
          `${name}:${marker.at + 1}: list-cap ${marker.cap} is ${value}, above ${MAX_CAP}; a list that long registers with the list contract`,
        );
      return;
    }
    options.trace?.(at, "unregistered");
    loops.push(at);
  };

  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
      const method = node.expression.name.text;
      const receiver = node.expression.expression;
      const children = /^(?:React\.)?Children$/.test(receiver.getText(source));
      if ((method === "map" || method === "flatMap") && !children && resolver.returnsJsx(module, node.arguments[0]))
        consider(node, () => resolver.constant(module, receiver));
      else if (calleeName(node) === "Array.from" && resolver.returnsJsx(module, node.arguments[1]))
        consider(node, () => resolver.constant(module, node));
    } else if ((ts.isForOfStatement(node) || ts.isForInStatement(node)) && pushesJsx(resolver, module, node.statement))
      consider(node, () =>
        ts.isForInStatement(node)
          ? !!resolver.object(module, node.expression, 0) || resolver.constant(module, node.expression)
          : resolver.constant(module, node.expression),
      );
    else if (ts.isForStatement(node) && pushesJsx(resolver, module, node.statement))
      consider(node, () => {
        const condition = node.condition && unwrap(node.condition);
        if (!condition || !ts.isBinaryExpression(condition)) return false;
        const op = condition.operatorToken.kind;
        if (op !== ts.SyntaxKind.LessThanToken && op !== ts.SyntaxKind.LessThanEqualsToken) return false;
        const bound = unwrap(condition.right);
        if (ts.isPropertyAccessExpression(bound) && bound.name.text === "length")
          return resolver.constant(module, bound.expression);
        const value = resolver.number(module, bound);
        return value !== undefined && value <= MAX_CAP;
      });
    else if ((ts.isWhileStatement(node) || ts.isDoStatement(node)) && pushesJsx(resolver, module, node.statement))
      consider(node, () => false);
    ts.forEachChild(node, visit);
  };
  visit(source);
  const order = (at: string) => Number(at.split(":")[1]);
  return { loops: loops.sort((a, b) => order(a) - order(b)), badCaps };
}

/** Every product .tsx's unregistered list loops (files with none are left out) and bad caps. */
export function scanSources(registry = readRegistry()): { found: Map<string, string[]>; badCaps: string[] } {
  const found = new Map<string, string[]>();
  const badCaps: string[] = [];
  for (const file of productSources()) {
    const relative = path.relative(root, file);
    const result = findUnregisteredLists(file, readFileSync(file, "utf8"), { registered: registry.get(relative) });
    if (result.loops.length) found.set(relative, result.loops);
    badCaps.push(...result.badCaps);
  }
  return { found, badCaps };
}

/** Registry entries that name a file or component that is not there: a renamed list falls out of the contract. */
export function staleRegistrations(registry: Map<string, Set<string>>): string[] {
  const stale: string[] = [];
  for (const [file, names] of registry) {
    const full = path.join(root, file);
    if (!file.startsWith("src/") || file.startsWith("src/test/")) continue;
    const text = existsSync(full) ? readFileSync(full, "utf8") : undefined;
    for (const component of names)
      if (!text || !new RegExp(`\\b(?:function|const|let)\\s+${component}\\b`).test(text))
        stale.push(`  ${file}#${component}`);
  }
  return stale;
}

/**
 * The baseline as one count per directory under src/ (a file's own directory, not its parents), most first,
 * then the total: the number to bring down, and where it is.
 */
export function byDirectory(counts: Map<string, number>): string[] {
  const directories = new Map<string, number>();
  for (const [file, count] of counts) {
    const directory = path.posix.relative("src", path.posix.dirname(file)) || ".";
    directories.set(directory, (directories.get(directory) ?? 0) + count);
  }
  const total = [...counts.values()].reduce((a, b) => a + b, 0);
  return [
    ...[...directories]
      .sort(([a, x], [b, y]) => y - x || a.localeCompare(b))
      .map(([directory, count]) => `  ${directory} ${count}`),
    `  total ${total} unregistered list loops in ${counts.size} files`,
  ];
}

const HOW =
  'A list over the person\'s data registers with the list contract (test/support/listContract.ts): add test/list-contract/<name>.fixture.tsx (see test/list-contract/listFixture.ts) whose `source: "path#Export"` names the component that draws it. A collection that can never pass a fixed size says so with "// list-cap: NAME" on the loop\'s line or the line above, NAME a const number <= 100.';

if (import.meta.main) {
  const registry = readRegistry();
  const { found, badCaps } = scanSources(registry);
  const counts = new Map([...found].map(([file, loops]) => [file, loops.length]));
  const { grew, shrank } = compareToBaseline(
    found,
    readBaseline(existsSync(baselinePath) ? readFileSync(baselinePath, "utf8") : "", "list-contract-baseline.tsv"),
    (file) => existsSync(path.join(root, file)),
    "unregistered list loops",
  );
  const stale = staleRegistrations(registry);
  if (process.argv.includes("--update-baseline")) {
    if (grew.length && existsSync(baselinePath)) {
      console.error("check-unregistered-lists: refusing to raise the baseline; register the list instead.");
      console.error(HOW);
      console.error(grew.join("\n"));
      process.exit(1);
    }
    writeBaseline(
      counts,
      baselinePath,
      "Unregistered JSX list loops per file from before the rule (scripts/check-unregistered-lists.ts). Only moves down.",
    );
    console.log(`check-unregistered-lists: baseline written (${counts.size} files), per directory under src/:`);
    console.log(byDirectory(counts).join("\n"));
    process.exit(0);
  }
  if (grew.length) {
    console.error(`check-unregistered-lists: a JSX list loop is not in the list contract. ${HOW}`);
    console.error(grew.join("\n"));
  }
  if (badCaps.length) {
    console.error(`check-unregistered-lists: a list-cap names no const number <= ${MAX_CAP}:`);
    console.error(badCaps.map((cap) => `  ${cap}`).join("\n"));
  }
  if (stale.length) {
    console.error(
      "check-unregistered-lists: a list fixture's source names a component that is not in that file; point it at the list's component:",
    );
    console.error(stale.join("\n"));
  }
  if (shrank.length) {
    console.error(
      "check-unregistered-lists: fewer unregistered list loops than the baseline; lower it (bun scripts/check-unregistered-lists.ts --update-baseline):",
    );
    console.error(shrank.join("\n"));
  }
  if (grew.length || shrank.length || badCaps.length || stale.length) process.exitCode = 1;
  else {
    console.log("Unregistered list loops checked; the baseline per directory under src/:");
    console.log(byDirectory(counts).join("\n"));
  }
}
