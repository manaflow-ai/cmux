/**
 * Evaluator for parsed expressions, `${{ }}` templates and `if:` conditions.
 */

import { type Expr, parseExpression, usesStatusFunction } from "./parser.ts";
import {
  compare,
  ExpressionError,
  Filtered,
  getProperty,
  type Intermediate,
  isArray,
  isObject,
  looseEquals,
  settle,
  toText,
  truthy,
  type Value,
  type ValueObject,
} from "./value.ts";

export interface StatusFunctions {
  readonly success: () => boolean;
  readonly failure: () => boolean;
  readonly cancelled: () => boolean;
}

export interface EvalContext {
  /** Context name (lower case, e.g. `github`) to its value. A missing context reads as null. */
  readonly contexts: Readonly<Record<string, Value>>;
  readonly status?: StatusFunctions;
  readonly hashFiles?: (patterns: readonly string[]) => string;
}

const DEFAULT_STATUS: StatusFunctions = { success: () => true, failure: () => false, cancelled: () => false };

const access = (target: Intermediate, key: Intermediate): Intermediate => {
  if (target instanceof Filtered) {
    const out: Value[] = [];
    for (const item of target.items) {
      const value = access(item, key);
      if (value !== null && !(value instanceof Filtered)) out.push(value);
    }
    return new Filtered(out);
  }
  if (isObject(target)) {
    if (typeof key !== "string" && typeof key !== "number") return null;
    return getProperty(target, typeof key === "number" ? String(key) : key) ?? null;
  }
  if (isArray(target)) {
    const index = typeof key === "number" ? key : typeof key === "string" && /^\d+$/.test(key) ? Number(key) : Number.NaN;
    if (!Number.isInteger(index) || index < 0) return null;
    return target[index] ?? null;
  }
  return null;
};

const star = (target: Intermediate): Filtered => {
  if (target instanceof Filtered) {
    const out: Value[] = [];
    for (const item of target.items) {
      if (isArray(item)) out.push(...item);
      else if (isObject(item)) out.push(...Object.values(item));
    }
    return new Filtered(out);
  }
  if (isArray(target)) return new Filtered([...target]);
  if (isObject(target)) return new Filtered(Object.values(target));
  return new Filtered([]);
};

const format = (template: string, args: readonly Intermediate[]): string => {
  let out = "";
  let index = 0;
  while (index < template.length) {
    const char = template[index];
    if (char === "{") {
      if (template[index + 1] === "{") {
        out += "{";
        index += 2;
        continue;
      }
      const close = template.indexOf("}", index);
      const spec = close === -1 ? "" : template.slice(index + 1, close);
      if (!/^\d+$/.test(spec)) throw new ExpressionError(`format: invalid format string '${template}'`);
      const argIndex = Number(spec);
      if (argIndex >= args.length) throw new ExpressionError(`format: missing argument {${argIndex}} in '${template}'`);
      out += toText(args[argIndex] ?? null);
      index = close + 1;
      continue;
    }
    if (char === "}") {
      if (template[index + 1] === "}") {
        out += "}";
        index += 2;
        continue;
      }
      throw new ExpressionError(`format: unbalanced '}' in '${template}'`);
    }
    out += char;
    index += 1;
  }
  return out;
};

const fromJson = (text: Intermediate): Value => {
  if (typeof text !== "string") throw new ExpressionError(`fromJSON: expected a string, got ${toText(text) || "null"}`);
  if (text.trim() === "") throw new ExpressionError("fromJSON: empty input");
  try {
    return JSON.parse(text) as Value;
  } catch (error) {
    throw new ExpressionError(`fromJSON: ${error instanceof Error ? error.message : String(error)}`);
  }
};

export const evaluateExpr = (expr: Expr, context: EvalContext): Intermediate => {
  const status = context.status ?? DEFAULT_STATUS;
  const run = (node: Expr): Intermediate => {
    switch (node.kind) {
      case "literal":
        return node.value;
      case "context":
        return context.contexts[node.name] ?? null;
      case "not":
        return !truthy(run(node.operand));
      case "and": {
        const left = run(node.left);
        return truthy(left) ? run(node.right) : left;
      }
      case "or": {
        const left = run(node.left);
        return truthy(left) ? left : run(node.right);
      }
      case "binary": {
        const left = run(node.left);
        const right = run(node.right);
        switch (node.op) {
          case "==":
            return looseEquals(left, right);
          case "!=":
            return !looseEquals(left, right);
          default: {
            const order = compare(left, right);
            if (order === null) return false;
            if (node.op === "<") return order < 0;
            if (node.op === "<=") return order <= 0;
            if (node.op === ">") return order > 0;
            return order >= 0;
          }
        }
      }
      case "property":
        return access(run(node.target), node.name);
      case "index":
        return access(run(node.target), run(node.index));
      case "star":
        return star(run(node.target));
      case "call": {
        const args = node.args.map(run);
        const [first = null, second = null] = args;
        switch (node.name) {
          case "contains":
            if (first instanceof Filtered || isArray(first)) {
              const items = first instanceof Filtered ? first.items : first;
              return items.some((item) => looseEquals(item, second));
            }
            return toText(first).toUpperCase().includes(toText(second).toUpperCase());
          case "startsWith":
            return toText(first).toUpperCase().startsWith(toText(second).toUpperCase());
          case "endsWith":
            return toText(first).toUpperCase().endsWith(toText(second).toUpperCase());
          case "format":
            return format(toText(first), args.slice(1));
          case "join": {
            const separator = args.length > 1 ? toText(second) : ",";
            if (first instanceof Filtered || isArray(first)) {
              return (first instanceof Filtered ? first.items : first).map((item) => toText(item)).join(separator);
            }
            return typeof first === "string" ? first : toText(first);
          }
          case "toJSON":
            return JSON.stringify(settle(first), null, 2);
          case "fromJSON":
            return fromJson(first);
          case "hashFiles":
            if (context.hashFiles === undefined) throw new ExpressionError("hashFiles is only available in steps");
            return context.hashFiles(args.map((arg) => toText(arg)));
          case "success":
            return status.success();
          case "always":
            return true;
          case "cancelled":
            return status.cancelled();
          case "failure":
            return status.failure();
        }
      }
    }
  };
  return run(expr);
};

export const evaluate = (source: string, context: EvalContext): Value =>
  settle(evaluateExpr(parseExpression(source), context));

export type TemplatePart = { readonly text: string } | { readonly expr: Expr; readonly source: string };

/** True if the text contains a `${{` opener. */
export const hasExpression = (text: string): boolean => text.includes("${{");

/** Splits text into literal parts and `${{ }}` expressions. Quotes inside expressions may contain `}}`. */
export const parseTemplate = (text: string): TemplatePart[] => {
  const parts: TemplatePart[] = [];
  let cursor = 0;
  for (;;) {
    const open = text.indexOf("${{", cursor);
    if (open === -1) break;
    if (open > cursor) parts.push({ text: text.slice(cursor, open) });
    let index = open + 3;
    let inString = false;
    let close = -1;
    while (index < text.length) {
      const char = text[index];
      if (char === "'") inString = !inString;
      else if (!inString && char === "}" && text[index + 1] === "}") {
        close = index;
        break;
      }
      index += 1;
    }
    if (close === -1) throw new ExpressionError(`unclosed '\${{' in: ${text}`);
    const source = text.slice(open + 3, close).trim();
    parts.push({ expr: parseExpression(source), source });
    cursor = close + 2;
  }
  if (cursor < text.length) parts.push({ text: text.slice(cursor) });
  return parts;
};

const singleExpression = (parts: readonly TemplatePart[]): Expr | null => {
  const exprs = parts.filter((part): part is { expr: Expr; source: string } => "expr" in part);
  if (exprs.length !== 1) return null;
  const onlyWhitespace = parts.every((part) => "expr" in part || part.text.trim() === "");
  return onlyWhitespace ? (exprs[0]?.expr ?? null) : null;
};

/**
 * Evaluates a YAML scalar. A scalar that is exactly one `${{ }}` (surrounding
 * whitespace allowed) keeps the expression's type; mixed text becomes a string.
 */
export const evaluateTemplate = (text: string, context: EvalContext): Value => {
  if (!hasExpression(text)) return text;
  const parts = parseTemplate(text);
  const single = singleExpression(parts);
  if (single !== null) return settle(evaluateExpr(single, context));
  return parts.map((part) => ("expr" in part ? toText(evaluateExpr(part.expr, context)) : part.text)).join("");
};

/** Evaluates every string inside a parsed YAML value (keys stay literal). */
export const evaluateDeep = (value: Value, context: EvalContext): Value => {
  if (typeof value === "string") return evaluateTemplate(value, context);
  if (isArray(value)) return value.map((item) => evaluateDeep(item, context));
  if (isObject(value)) {
    const out: Record<string, Value> = {};
    for (const [key, item] of Object.entries(value as ValueObject)) out[key] = evaluateDeep(item, context);
    return out;
  }
  return value;
};

const SUCCESS_CALL: Expr = { kind: "call", name: "success", args: [] };

/**
 * Parses an `if:` condition. `${{ }}` around the whole condition is optional.
 * Without a status function the condition is `success() && (condition)`.
 * An empty condition is `success()`.
 */
export const parseCondition = (condition: string): Expr => {
  const trimmed = condition.trim();
  if (trimmed === "") return SUCCESS_CALL;
  let expr: Expr;
  if (hasExpression(trimmed)) {
    const parts = parseTemplate(trimmed);
    const single = singleExpression(parts);
    if (single === null) {
      throw new ExpressionError(`a condition must be one expression, not text with \${{ }} inside: ${condition}`);
    }
    expr = single;
  } else {
    expr = parseExpression(trimmed);
  }
  return usesStatusFunction(expr) ? expr : { kind: "and", left: SUCCESS_CALL, right: expr };
};

export const evaluateCondition = (condition: string, context: EvalContext): boolean =>
  truthy(evaluateExpr(parseCondition(condition), context));
