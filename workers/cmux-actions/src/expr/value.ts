/**
 * Values and coercion rules of GitHub Actions expressions.
 *
 * Reference: https://docs.github.com/en/actions/reference/workflows-and-actions/expressions
 * (literals, operators, type coercion) and the actions/runner expression engine.
 */

export type Value = null | boolean | number | string | ValueArray | ValueObject;
export interface ValueArray extends ReadonlyArray<Value> {}
export interface ValueObject {
  readonly [key: string]: Value;
}

/** The result of `x.*`: property access maps over the items. */
export class Filtered {
  constructor(readonly items: readonly Value[]) {}
}

export type Intermediate = Value | Filtered;

export class ExpressionError extends Error {
  override readonly name = "ExpressionError";
}

export const isArray = (value: Intermediate): value is ValueArray => Array.isArray(value);

export const isObject = (value: Intermediate): value is ValueObject =>
  typeof value === "object" && value !== null && !Array.isArray(value) && !(value instanceof Filtered);

/** Converts a filtered array back to a plain array; other values pass through. */
export const settle = (value: Intermediate): Value => (value instanceof Filtered ? [...value.items] : value);

/** Converts parsed YAML or JSON into a Value. Undefined becomes null. */
export const toValue = (input: unknown): Value => {
  if (input === null || input === undefined) return null;
  if (typeof input === "boolean" || typeof input === "number" || typeof input === "string") return input;
  if (typeof input === "bigint") return Number(input);
  if (Array.isArray(input)) return input.map(toValue);
  if (input instanceof Date) return input.toISOString();
  if (typeof input === "object") {
    const out: Record<string, Value> = {};
    for (const [key, item] of Object.entries(input)) out[key] = toValue(item);
    return out;
  }
  return null;
};

export const truthy = (value: Intermediate): boolean => {
  if (value instanceof Filtered) return true;
  if (value === null) return false;
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0 && !Number.isNaN(value);
  if (typeof value === "string") return value.length > 0;
  return true;
};

export const toNumber = (value: Intermediate): number => {
  if (value === null) return 0;
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed === "") return 0;
    if (/^[+-]?(infinity|nan)$/i.test(trimmed)) return Number.NaN;
    if (/^0x[0-9a-f]+$/i.test(trimmed)) return Number.parseInt(trimmed.slice(2), 16);
    if (!/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(trimmed)) return Number.NaN;
    return Number(trimmed);
  }
  return Number.NaN;
};

export const numberToString = (value: number): string => {
  if (Number.isNaN(value)) return "NaN";
  if (value === Number.POSITIVE_INFINITY) return "Infinity";
  if (value === Number.NEGATIVE_INFINITY) return "-Infinity";
  if (Object.is(value, -0)) return "0";
  if (Number.isInteger(value)) return value.toString();
  return Number.parseFloat(value.toPrecision(15)).toString();
};

/** String form used by interpolation, `format`, `join` and string functions. */
export const toText = (value: Intermediate): string => {
  if (value === null) return "";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return numberToString(value);
  if (typeof value === "string") return value;
  if (value instanceof Filtered || Array.isArray(value)) return "Array";
  return "Object";
};

const kind = (value: Intermediate): "null" | "boolean" | "number" | "string" | "array" | "object" => {
  if (value === null) return "null";
  if (typeof value === "boolean") return "boolean";
  if (typeof value === "number") return "number";
  if (typeof value === "string") return "string";
  if (value instanceof Filtered || Array.isArray(value)) return "array";
  return "object";
};

const upper = (text: string): string => text.toUpperCase();

/** `==`: same kinds compare directly (strings ignore case); otherwise both become numbers. */
export const looseEquals = (left: Intermediate, right: Intermediate): boolean => {
  const leftKind = kind(left);
  const rightKind = kind(right);
  if (leftKind === rightKind) {
    if (leftKind === "string") return upper(left as string) === upper(right as string);
    if (leftKind === "number") return (left as number) === (right as number);
    if (leftKind === "array" || leftKind === "object") return left === right;
    return left === right;
  }
  if (leftKind === "array" || leftKind === "object" || rightKind === "array" || rightKind === "object") return false;
  const a = toNumber(left);
  const b = toNumber(right);
  return !Number.isNaN(a) && !Number.isNaN(b) && a === b;
};

/** `<`, `<=`, `>`, `>=`: strings compare ordinally ignoring case; otherwise numbers. */
export const compare = (left: Intermediate, right: Intermediate): number | null => {
  if (typeof left === "string" && typeof right === "string") {
    const a = upper(left);
    const b = upper(right);
    return a < b ? -1 : a > b ? 1 : 0;
  }
  const a = toNumber(left);
  const b = toNumber(right);
  if (Number.isNaN(a) || Number.isNaN(b)) return null;
  return a < b ? -1 : a > b ? 1 : 0;
};

/** Case-insensitive property lookup, exact match first. */
export const getProperty = (object: ValueObject, key: string): Value | undefined => {
  if (Object.hasOwn(object, key)) return object[key];
  const wanted = upper(key);
  for (const name of Object.keys(object)) {
    if (upper(name) === wanted) return object[name];
  }
  return undefined;
};
