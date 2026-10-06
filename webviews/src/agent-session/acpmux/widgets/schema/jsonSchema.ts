// A small JSON Schema (draft 2020-12) validator for the thread widget contract (schemas/widgets).
// It implements only the keywords the widget schemas use, with standard semantics, and refuses a
// schema that uses any other keyword, so a schema can never rely on a keyword that this validator
// would silently ignore. $ref resolves by URL against the document's $id, with a JSON Pointer
// fragment. Objects are read by own keys only, so a key such as __proto__ is an ordinary key.

export type SchemaIssue = { path: string; keyword: string; message: string };

type SchemaObject = { readonly [keyword: string]: unknown };
type Schema = boolean | SchemaObject;

const ANNOTATIONS = new Set(["$schema", "$id", "$comment", "$defs", "title", "description", "default", "examples"]);
const ASSERTIONS = new Set([
  "$ref",
  "type",
  "const",
  "enum",
  "properties",
  "required",
  "additionalProperties",
  "propertyNames",
  "minProperties",
  "maxProperties",
  "items",
  "prefixItems",
  "contains",
  "minItems",
  "maxItems",
  "uniqueItems",
  "minLength",
  "maxLength",
  "pattern",
  "minimum",
  "maximum",
  "multipleOf",
  "allOf",
  "anyOf",
  "oneOf",
  "not",
  "if",
  "then",
  "else",
]);
const SCHEMA_MAP_KEYWORDS = ["properties", "$defs"];
const SCHEMA_LIST_KEYWORDS = ["allOf", "anyOf", "oneOf", "prefixItems"];
const SCHEMA_KEYWORDS = ["additionalProperties", "propertyNames", "items", "contains", "not", "if", "then", "else"];

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const own = (value: Record<string, unknown>, key: string) => Object.prototype.hasOwnProperty.call(value, key);

const pointerToken = (token: string) => token.replaceAll("~1", "/").replaceAll("~0", "~");

const escapeToken = (token: string) => token.replaceAll("~", "~0").replaceAll("/", "~1");

/// Code points, the JSON Schema length unit.
export function codePointLength(text: string): number {
  let count = 0;
  for (let index = 0; index < text.length; index += 1) {
    const unit = text.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) index += 1;
    }
    count += 1;
  }
  return count;
}

/// JSON equality: numbers by value, objects by own keys regardless of order.
export function jsonEqual(left: unknown, right: unknown): boolean {
  if (left === right) return true;
  if (Array.isArray(left) && Array.isArray(right)) {
    return left.length === right.length && left.every((item, index) => jsonEqual(item, right[index]));
  }
  if (isObject(left) && isObject(right)) {
    const keys = Object.keys(left);
    return (
      keys.length === Object.keys(right).length &&
      keys.every((key) => own(right, key) && jsonEqual(left[key], right[key]))
    );
  }
  return false;
}

function typeMatches(type: string, value: unknown): boolean {
  switch (type) {
    case "null":
      return value === null;
    case "boolean":
      return typeof value === "boolean";
    case "string":
      return typeof value === "string";
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "array":
      return Array.isArray(value);
    case "object":
      return isObject(value);
    default:
      throw new Error(`unknown JSON Schema type ${type}`);
  }
}

export class SchemaSet {
  private readonly documents = new Map<string, SchemaObject>();
  private readonly patterns = new Map<string, RegExp>();

  constructor(documents: readonly unknown[]) {
    for (const document of documents) {
      if (!isObject(document) || typeof document.$id !== "string")
        throw new Error("every schema document needs an $id");
      if (this.documents.has(document.$id)) throw new Error(`duplicate schema $id ${document.$id}`);
      this.checkKeywords(document, document.$id);
      this.documents.set(document.$id, document);
    }
    for (const [id, document] of this.documents) this.checkRefs(document, id, id);
  }

  /// The issues of `value` against the schema at `ref` (an absolute $id, optionally with a
  /// #/json/pointer fragment). An empty list means valid.
  validate(ref: string, value: unknown): SchemaIssue[] {
    const issues: SchemaIssue[] = [];
    const { schema, base } = this.resolve(ref, ref);
    this.check(schema, value, "", base, issues);
    return issues;
  }

  private checkKeywords(schema: unknown, where: string) {
    if (typeof schema === "boolean") return;
    if (!isObject(schema)) throw new Error(`${where}: a schema must be an object or a boolean`);
    for (const keyword of Object.keys(schema)) {
      if (!ANNOTATIONS.has(keyword) && !ASSERTIONS.has(keyword))
        throw new Error(`${where}: unsupported keyword ${keyword}`);
    }
    for (const keyword of SCHEMA_MAP_KEYWORDS) {
      const map = schema[keyword];
      if (map === undefined) continue;
      if (!isObject(map)) throw new Error(`${where}/${keyword}: must be an object`);
      for (const [name, sub] of Object.entries(map))
        this.checkKeywords(sub, `${where}/${keyword}/${escapeToken(name)}`);
    }
    for (const keyword of SCHEMA_LIST_KEYWORDS) {
      const list = schema[keyword];
      if (list === undefined) continue;
      if (!Array.isArray(list) || list.length === 0) throw new Error(`${where}/${keyword}: must be a non-empty array`);
      list.forEach((sub, index) => this.checkKeywords(sub, `${where}/${keyword}/${index}`));
    }
    for (const keyword of SCHEMA_KEYWORDS) {
      if (schema[keyword] !== undefined) this.checkKeywords(schema[keyword], `${where}/${keyword}`);
    }
    if (typeof schema.pattern === "string") this.regex(schema.pattern);
  }

  private checkRefs(schema: unknown, base: string, where: string) {
    if (!isObject(schema)) return;
    if (typeof schema.$ref === "string") this.resolve(schema.$ref, base);
    for (const keyword of SCHEMA_MAP_KEYWORDS) {
      if (isObject(schema[keyword])) {
        for (const [name, sub] of Object.entries(schema[keyword]))
          this.checkRefs(sub, base, `${where}/${keyword}/${name}`);
      }
    }
    for (const keyword of SCHEMA_LIST_KEYWORDS) {
      if (Array.isArray(schema[keyword]))
        schema[keyword].forEach((sub: unknown, index: number) =>
          this.checkRefs(sub, base, `${where}/${keyword}/${index}`),
        );
    }
    for (const keyword of SCHEMA_KEYWORDS) this.checkRefs(schema[keyword], base, `${where}/${keyword}`);
  }

  private resolve(ref: string, base: string): { schema: Schema; base: string } {
    const url = new URL(ref, base);
    const fragment = decodeURIComponent(url.hash.replace(/^#/, ""));
    url.hash = "";
    const id = url.toString();
    const document = this.documents.get(id);
    if (!document) throw new Error(`unresolved $ref ${ref} (from ${base})`);
    let schema: unknown = document;
    if (fragment) {
      if (!fragment.startsWith("/")) throw new Error(`$ref ${ref}: only JSON Pointer fragments are supported`);
      for (const token of fragment.slice(1).split("/").map(pointerToken)) {
        if (!isObject(schema) && !Array.isArray(schema)) throw new Error(`unresolved $ref ${ref}`);
        schema = (schema as Record<string, unknown>)[token];
      }
    }
    if (typeof schema !== "boolean" && !isObject(schema)) throw new Error(`unresolved $ref ${ref}`);
    return { schema, base: id };
  }

  private regex(pattern: string): RegExp {
    let compiled = this.patterns.get(pattern);
    if (!compiled) {
      compiled = new RegExp(pattern, "u");
      this.patterns.set(pattern, compiled);
    }
    return compiled;
  }

  private passes(schema: Schema, value: unknown, path: string, base: string): boolean {
    const issues: SchemaIssue[] = [];
    this.check(schema, value, path, base, issues);
    return issues.length === 0;
  }

  private check(schema: Schema, value: unknown, path: string, base: string, issues: SchemaIssue[]) {
    if (schema === true) return;
    if (schema === false) {
      issues.push({ path, keyword: "false", message: "no value is allowed here" });
      return;
    }
    const fail = (keyword: string, message: string) => issues.push({ path, keyword, message });
    if (typeof schema.$ref === "string") {
      const target = this.resolve(schema.$ref, base);
      this.check(target.schema, value, path, target.base, issues);
    }
    if (schema.type !== undefined) {
      const types = Array.isArray(schema.type) ? (schema.type as string[]) : [schema.type as string];
      if (!types.some((type) => typeMatches(type, value))) {
        fail("type", `expected ${types.join(" or ")}`);
        return;
      }
    }
    if (own(schema, "const") && !jsonEqual(schema.const, value))
      fail("const", `expected ${JSON.stringify(schema.const)}`);
    if (Array.isArray(schema.enum) && !schema.enum.some((option) => jsonEqual(option, value)))
      fail("enum", "not one of the allowed values");
    if (typeof value === "string") this.checkString(schema, value, fail);
    if (typeof value === "number") this.checkNumber(schema, value, fail);
    if (Array.isArray(value)) this.checkArray(schema, value, path, base, issues, fail);
    if (isObject(value)) this.checkObject(schema, value, path, base, issues, fail);
    this.checkCombinators(schema, value, path, base, issues, fail);
  }

  private checkString(schema: SchemaObject, value: string, fail: (keyword: string, message: string) => void) {
    const needsLength = typeof schema.minLength === "number" || typeof schema.maxLength === "number";
    const length = needsLength ? codePointLength(value) : 0;
    if (typeof schema.minLength === "number" && length < schema.minLength)
      fail("minLength", `shorter than ${schema.minLength}`);
    if (typeof schema.maxLength === "number" && length > schema.maxLength)
      fail("maxLength", `longer than ${schema.maxLength}`);
    if (typeof schema.pattern === "string" && !this.regex(schema.pattern).test(value))
      fail("pattern", `does not match ${schema.pattern}`);
  }

  private checkNumber(schema: SchemaObject, value: number, fail: (keyword: string, message: string) => void) {
    if (typeof schema.minimum === "number" && value < schema.minimum) fail("minimum", `below ${schema.minimum}`);
    if (typeof schema.maximum === "number" && value > schema.maximum) fail("maximum", `above ${schema.maximum}`);
    if (typeof schema.multipleOf === "number" && !Number.isInteger(value / schema.multipleOf))
      fail("multipleOf", `not a multiple of ${schema.multipleOf}`);
  }

  private checkArray(
    schema: SchemaObject,
    value: unknown[],
    path: string,
    base: string,
    issues: SchemaIssue[],
    fail: (keyword: string, message: string) => void,
  ) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems)
      fail("minItems", `fewer than ${schema.minItems} items`);
    if (typeof schema.maxItems === "number" && value.length > schema.maxItems)
      fail("maxItems", `more than ${schema.maxItems} items`);
    if (schema.uniqueItems === true) {
      for (let left = 0; left < value.length; left += 1) {
        for (let right = left + 1; right < value.length; right += 1) {
          if (jsonEqual(value[left], value[right])) {
            fail("uniqueItems", `items ${left} and ${right} are equal`);
            left = value.length;
            break;
          }
        }
      }
    }
    const prefix = Array.isArray(schema.prefixItems) ? (schema.prefixItems as Schema[]) : [];
    value.forEach((item, index) => {
      const itemSchema = index < prefix.length ? prefix[index] : (schema.items as Schema | undefined);
      if (itemSchema !== undefined) this.check(itemSchema, item, `${path}/${index}`, base, issues);
    });
    if (
      schema.contains !== undefined &&
      !value.some((item, index) => this.passes(schema.contains as Schema, item, `${path}/${index}`, base))
    ) {
      fail("contains", "no item matches");
    }
  }

  private checkObject(
    schema: SchemaObject,
    value: Record<string, unknown>,
    path: string,
    base: string,
    issues: SchemaIssue[],
    fail: (keyword: string, message: string) => void,
  ) {
    const keys = Object.keys(value);
    if (typeof schema.minProperties === "number" && keys.length < schema.minProperties)
      fail("minProperties", `fewer than ${schema.minProperties} fields`);
    if (typeof schema.maxProperties === "number" && keys.length > schema.maxProperties)
      fail("maxProperties", `more than ${schema.maxProperties} fields`);
    if (Array.isArray(schema.required)) {
      for (const key of schema.required as string[]) if (!own(value, key)) fail("required", `missing field ${key}`);
    }
    const properties = isObject(schema.properties) ? schema.properties : {};
    for (const key of keys) {
      const childPath = `${path}/${escapeToken(key)}`;
      if (schema.propertyNames !== undefined) this.check(schema.propertyNames as Schema, key, childPath, base, issues);
      if (own(properties, key)) this.check(properties[key] as Schema, value[key], childPath, base, issues);
      else if (schema.additionalProperties !== undefined)
        this.check(schema.additionalProperties as Schema, value[key], childPath, base, issues);
    }
  }

  private checkCombinators(
    schema: SchemaObject,
    value: unknown,
    path: string,
    base: string,
    issues: SchemaIssue[],
    fail: (keyword: string, message: string) => void,
  ) {
    if (Array.isArray(schema.allOf))
      for (const sub of schema.allOf as Schema[]) this.check(sub, value, path, base, issues);
    if (Array.isArray(schema.anyOf) && !(schema.anyOf as Schema[]).some((sub) => this.passes(sub, value, path, base)))
      fail("anyOf", "matches no option");
    if (Array.isArray(schema.oneOf)) {
      const matches = (schema.oneOf as Schema[]).filter((sub) => this.passes(sub, value, path, base)).length;
      if (matches !== 1)
        fail("oneOf", matches === 0 ? "matches no option" : `matches ${matches} options, expected one`);
    }
    if (schema.not !== undefined && this.passes(schema.not as Schema, value, path, base))
      fail("not", "matches a forbidden shape");
    if (schema.if !== undefined) {
      const branch = this.passes(schema.if as Schema, value, path, base) ? schema.then : schema.else;
      if (branch !== undefined) this.check(branch as Schema, value, path, base, issues);
    }
  }
}
