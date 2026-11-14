/**
 * Lexer and parser for the GitHub Actions expression language (the text
 * inside `${{ }}` and `if:` conditions).
 *
 * Grammar, lowest precedence first:
 *   or      := and ("||" and)*
 *   and     := equal ("&&" equal)*
 *   equal   := compare (("==" | "!=") compare)*
 *   compare := unary (("<" | "<=" | ">" | ">=") unary)*
 *   unary   := "!" unary | postfix
 *   postfix := primary ("." (name | "*") | "[" or "]")*
 *   primary := literal | "(" or ")" | name "(" args ")" | name
 * Names may contain "-" (there is no subtraction operator).
 */

import { ExpressionError, type Value } from "./value.ts";

export type Expr =
  | { readonly kind: "literal"; readonly value: Value }
  | { readonly kind: "context"; readonly name: ContextName }
  | { readonly kind: "not"; readonly operand: Expr }
  | { readonly kind: "and" | "or"; readonly left: Expr; readonly right: Expr }
  | {
      readonly kind: "binary";
      readonly op: "==" | "!=" | "<" | "<=" | ">" | ">=";
      readonly left: Expr;
      readonly right: Expr;
    }
  | { readonly kind: "property"; readonly target: Expr; readonly name: string }
  | { readonly kind: "index"; readonly target: Expr; readonly index: Expr }
  | { readonly kind: "star"; readonly target: Expr }
  | { readonly kind: "call"; readonly name: FunctionName; readonly args: readonly Expr[] };

export const CONTEXT_NAMES = [
  "github",
  "env",
  "vars",
  "secrets",
  "inputs",
  "matrix",
  "strategy",
  "needs",
  "jobs",
  "steps",
  "runner",
  "job",
] as const;
export type ContextName = (typeof CONTEXT_NAMES)[number];

/** Function name (canonical case) to [minimum, maximum] argument count. */
export const FUNCTIONS = {
  contains: [2, 2],
  startsWith: [2, 2],
  endsWith: [2, 2],
  format: [1, Number.POSITIVE_INFINITY],
  join: [1, 2],
  toJSON: [1, 1],
  fromJSON: [1, 1],
  hashFiles: [1, Number.POSITIVE_INFINITY],
  success: [0, 0],
  always: [0, 0],
  cancelled: [0, 0],
  failure: [0, 0],
} as const;
export type FunctionName = keyof typeof FUNCTIONS;

export const STATUS_FUNCTIONS: ReadonlySet<FunctionName> = new Set(["success", "always", "cancelled", "failure"]);

type Token =
  | { readonly type: "number"; readonly value: number; readonly at: number }
  | { readonly type: "string"; readonly value: string; readonly at: number }
  | { readonly type: "name"; readonly value: string; readonly at: number }
  | { readonly type: "punct"; readonly value: string; readonly at: number }
  | { readonly type: "end"; readonly at: number };

const NUMBER = /^-?(?:0x[0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/;
const NAME = /^[A-Za-z_][A-Za-z0-9_-]*/;
const PUNCT = ["==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "(", ")", "[", "]", ",", ".", "*"];

export const tokenize = (source: string): Token[] => {
  const tokens: Token[] = [];
  let at = 0;
  while (at < source.length) {
    const char = source[at] ?? "";
    if (/\s/.test(char)) {
      at += 1;
      continue;
    }
    const rest = source.slice(at);
    if (char === "'") {
      let value = "";
      let index = at + 1;
      for (;;) {
        if (index >= source.length) throw new ExpressionError(`unterminated string at ${at} in: ${source}`);
        const current = source[index];
        if (current === "'") {
          if (source[index + 1] === "'") {
            value += "'";
            index += 2;
            continue;
          }
          break;
        }
        value += current;
        index += 1;
      }
      tokens.push({ type: "string", value, at });
      at = index + 1;
      continue;
    }
    const previous = tokens.at(-1);
    const numberAllowed =
      previous === undefined || (previous.type === "punct" && previous.value !== ")" && previous.value !== "]");
    const number = NUMBER.exec(rest);
    if (number !== null && (/[0-9.]/.test(char) || (char === "-" && numberAllowed))) {
      const text = number[0];
      const value = /^-?0x/i.test(text)
        ? (text.startsWith("-") ? -1 : 1) * Number.parseInt(text.replace(/^-?0x/i, ""), 16)
        : Number(text);
      tokens.push({ type: "number", value, at });
      at += text.length;
      continue;
    }
    const name = NAME.exec(rest);
    if (name !== null) {
      tokens.push({ type: "name", value: name[0], at });
      at += name[0].length;
      continue;
    }
    const punct = PUNCT.find((candidate) => rest.startsWith(candidate));
    if (punct !== undefined) {
      tokens.push({ type: "punct", value: punct, at });
      at += punct.length;
      continue;
    }
    throw new ExpressionError(`unexpected character '${char}' at ${at} in: ${source}`);
  }
  tokens.push({ type: "end", at });
  return tokens;
};

const canonicalFunction = (name: string): FunctionName | undefined =>
  (Object.keys(FUNCTIONS) as FunctionName[]).find((candidate) => candidate.toLowerCase() === name.toLowerCase());

const canonicalContext = (name: string): ContextName | undefined =>
  CONTEXT_NAMES.find((candidate) => candidate === name.toLowerCase());

export const parseExpression = (source: string): Expr => {
  const tokens = tokenize(source);
  let position = 0;
  const peek = (): Token => tokens[position] ?? { type: "end", at: source.length };
  const next = (): Token => {
    const token = peek();
    position += 1;
    return token;
  };
  const isPunct = (value: string): boolean => {
    const token = peek();
    return token.type === "punct" && token.value === value;
  };
  const punctValue = (): string => {
    const token = next();
    if (token.type !== "punct") throw new ExpressionError(`expected an operator at ${token.at} in: ${source}`);
    return token.value;
  };
  const expectPunct = (value: string): void => {
    const token = next();
    if (token.type !== "punct" || token.value !== value) {
      throw new ExpressionError(`expected '${value}' at ${token.at} in: ${source}`);
    }
  };

  const parseOr = (): Expr => {
    let left = parseAnd();
    while (isPunct("||")) {
      next();
      left = { kind: "or", left, right: parseAnd() };
    }
    return left;
  };
  const parseAnd = (): Expr => {
    let left = parseEqual();
    while (isPunct("&&")) {
      next();
      left = { kind: "and", left, right: parseEqual() };
    }
    return left;
  };
  const parseEqual = (): Expr => {
    let left = parseCompare();
    while (isPunct("==") || isPunct("!=")) {
      const op = punctValue();
      left = { kind: "binary", op: op as "==" | "!=", left, right: parseCompare() };
    }
    return left;
  };
  const parseCompare = (): Expr => {
    let left = parseUnary();
    while (isPunct("<") || isPunct("<=") || isPunct(">") || isPunct(">=")) {
      const op = punctValue();
      left = { kind: "binary", op: op as "<" | "<=" | ">" | ">=", left, right: parseUnary() };
    }
    return left;
  };
  const parseUnary = (): Expr => {
    if (isPunct("!")) {
      next();
      return { kind: "not", operand: parseUnary() };
    }
    return parsePostfix(parsePrimary());
  };
  const parsePostfix = (start: Expr): Expr => {
    let target = start;
    for (;;) {
      if (isPunct(".")) {
        next();
        const token = next();
        if (token.type === "punct" && token.value === "*") target = { kind: "star", target };
        else if (token.type === "name") target = { kind: "property", target, name: token.value };
        else throw new ExpressionError(`expected a property name at ${token.at} in: ${source}`);
        continue;
      }
      if (isPunct("[")) {
        next();
        if (isPunct("*")) {
          next();
          expectPunct("]");
          target = { kind: "star", target };
          continue;
        }
        const index = parseOr();
        expectPunct("]");
        target = { kind: "index", target, index };
        continue;
      }
      return target;
    }
  };
  const parsePrimary = (): Expr => {
    const token = next();
    if (token.type === "number" || token.type === "string") return { kind: "literal", value: token.value };
    if (token.type === "punct" && token.value === "(") {
      const inner = parseOr();
      expectPunct(")");
      return inner;
    }
    if (token.type === "name") {
      const lower = token.value.toLowerCase();
      if (isPunct("(")) {
        next();
        const name = canonicalFunction(token.value);
        if (name === undefined) throw new ExpressionError(`unrecognized function '${token.value}' in: ${source}`);
        const args: Expr[] = [];
        if (!isPunct(")")) {
          args.push(parseOr());
          while (isPunct(",")) {
            next();
            args.push(parseOr());
          }
        }
        expectPunct(")");
        const [min, max] = FUNCTIONS[name];
        if (args.length < min || args.length > max) {
          throw new ExpressionError(`${name} takes ${min}${max === min ? "" : ` to ${max}`} arguments, got ${args.length} in: ${source}`);
        }
        return { kind: "call", name, args };
      }
      if (lower === "true") return { kind: "literal", value: true };
      if (lower === "false") return { kind: "literal", value: false };
      if (lower === "null") return { kind: "literal", value: null };
      if (lower === "nan") return { kind: "literal", value: Number.NaN };
      if (lower === "infinity") return { kind: "literal", value: Number.POSITIVE_INFINITY };
      const context = canonicalContext(token.value);
      if (context === undefined) throw new ExpressionError(`unrecognized named-value '${token.value}' in: ${source}`);
      return { kind: "context", name: context };
    }
    throw new ExpressionError(`unexpected token at ${token.at} in: ${source}`);
  };

  if (peek().type === "end") throw new ExpressionError("empty expression");
  const expr = parseOr();
  const rest = peek();
  if (rest.type !== "end") throw new ExpressionError(`unexpected token at ${rest.at} in: ${source}`);
  return expr;
};

/** Every node in the tree, depth first. */
export function* walk(expr: Expr): Generator<Expr> {
  yield expr;
  switch (expr.kind) {
    case "not":
      yield* walk(expr.operand);
      return;
    case "and":
    case "or":
    case "binary":
      yield* walk(expr.left);
      yield* walk(expr.right);
      return;
    case "property":
    case "star":
      yield* walk(expr.target);
      return;
    case "index":
      yield* walk(expr.target);
      yield* walk(expr.index);
      return;
    case "call":
      for (const arg of expr.args) yield* walk(arg);
      return;
    default:
      return;
  }
}

/** True if the expression calls success(), always(), cancelled() or failure(). */
export const usesStatusFunction = (expr: Expr): boolean => {
  for (const node of walk(expr)) {
    if (node.kind === "call" && STATUS_FUNCTIONS.has(node.name)) return true;
  }
  return false;
};

/** Context references with their first property when it is a literal name, e.g. `secrets.TOKEN`. */
export const contextReferences = (expr: Expr): Array<{ readonly context: ContextName; readonly property: string | null }> => {
  const found: Array<{ context: ContextName; property: string | null }> = [];
  const seen = new Set<Expr>();
  for (const node of walk(expr)) {
    if (node.kind === "property" && node.target.kind === "context") {
      found.push({ context: node.target.name, property: node.name });
      seen.add(node.target);
    } else if (
      node.kind === "index" &&
      node.target.kind === "context" &&
      node.index.kind === "literal" &&
      typeof node.index.value === "string"
    ) {
      found.push({ context: node.target.name, property: node.index.value });
      seen.add(node.target);
    }
  }
  for (const node of walk(expr)) {
    if (node.kind === "context" && !seen.has(node)) found.push({ context: node.name, property: null });
  }
  return found;
};
