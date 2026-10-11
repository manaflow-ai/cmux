// Compiles the JSON Schema 2020-12 subset the IR uses into TypeScript types and into
// straight-line validator code. Keywords outside the subset fail the codegen, so a new
// schemars output shape is caught at generation time, not by a silently permissive validator.

import { IrError, type JsonSchema } from "./ir";

export const ANNOTATIONS: ReadonlySet<string> = new Set([
  "$schema",
  "$id",
  "$comment",
  "title",
  "description",
  "default",
  "examples",
  "deprecated",
  "readOnly",
  "writeOnly",
]);

export const SUPPORTED: ReadonlySet<string> = new Set([
  "type",
  "$ref",
  "properties",
  "required",
  "additionalProperties",
  "items",
  "enum",
  "const",
  "anyOf",
  "oneOf",
  "allOf",
  "minimum",
  "maximum",
  "exclusiveMinimum",
  "exclusiveMaximum",
  "minLength",
  "maxLength",
  "pattern",
  "minItems",
  "maxItems",
  "format",
  // Decision 21: marks a secret property in a result or event. emit-ir derives each op's
  // `secret_output` from it; generators only check that it is a boolean.
  "x-cmux-secret",
]);

const TYPE_NAMES = new Set(["object", "array", "string", "integer", "number", "boolean", "null"]);

/** Integer formats schemars emits, with the range a receiver must enforce. */
const INTEGER_FORMATS: Record<string, [number, number]> = {
  int8: [-128, 127],
  int16: [-32768, 32767],
  int32: [-2147483648, 2147483647],
  int64: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER],
  uint8: [0, 255],
  uint16: [0, 65535],
  uint32: [0, 4294967295],
  uint64: [0, Number.MAX_SAFE_INTEGER],
  uint: [0, Number.MAX_SAFE_INTEGER],
  int: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER],
};

type SchemaObject = { [keyword: string]: unknown };

export function refName(ref: string, types: Record<string, JsonSchema>, where: string): string {
  const match = /^#\/(?:types|\$defs)\/([A-Za-z_][A-Za-z0-9_]*)$/.exec(ref);
  if (!match) throw new IrError(`${where}: unsupported $ref ${JSON.stringify(ref)} (only #/types/<Name>)`);
  if (!(match[1] in types)) throw new IrError(`${where}: $ref to unknown type ${match[1]}`);
  return match[1];
}

function checkKeywords(schema: SchemaObject, where: string): void {
  for (const key of Object.keys(schema)) {
    if (!SUPPORTED.has(key) && !ANNOTATIONS.has(key)) {
      throw new IrError(`${where}: JSON Schema keyword ${JSON.stringify(key)} is outside the supported subset`);
    }
  }
  if (schema["x-cmux-secret"] !== undefined && typeof schema["x-cmux-secret"] !== "boolean") {
    throw new IrError(`${where}: x-cmux-secret must be a boolean`);
  }
}

/**
 * Decision 19: a `pattern` must mean the same in RE2 (Rust, Go) and ECMA-262 (TS), so
 * lookaround, backreferences and named groups (whose syntax differs) are refused.
 */
export function checkPortablePattern(pattern: string, where: string): void {
  const refusals: Array<[RegExp, string]> = [
    [/\(\?<?[=!]/, "lookaround"],
    [/\\[1-9]/, "a backreference"],
    [/\\k</, "a named backreference"],
    [/\(\?P?<[A-Za-z_]/, "a named group"],
  ];
  for (const [refused, what] of refusals) {
    if (refused.test(pattern)) throw new IrError(`${where}: pattern uses ${what}, which RE2 and ECMA-262 do not share`);
  }
}

function typeList(schema: SchemaObject, where: string): string[] | null {
  const raw = schema.type;
  if (raw === undefined) return null;
  const list = Array.isArray(raw) ? raw : [raw];
  for (const name of list) {
    if (typeof name !== "string" || !TYPE_NAMES.has(name))
      throw new IrError(`${where}: bad type ${JSON.stringify(name)}`);
  }
  return list as string[];
}

function isPrimitive(value: unknown): value is string | number | boolean | null {
  return value === null || ["string", "number", "boolean"].includes(typeof value);
}

function schemaList(value: unknown, keyword: string, where: string): JsonSchema[] {
  if (!Array.isArray(value) || value.length === 0) throw new IrError(`${where}: ${keyword} must be a non-empty array`);
  return value as JsonSchema[];
}

function propertyKey(name: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name) ? name : JSON.stringify(name);
}

// TypeScript types

/** JSDoc from a schema's `description` (schemars copies Rust doc comments there), or "". */
export function docComment(schema: JsonSchema, indent: string): string {
  if (typeof schema !== "object") return "";
  const secret = schema["x-cmux-secret"] === true ? "Secret (x-cmux-secret): never shown to agents or logged." : "";
  const text = [typeof schema.description === "string" ? schema.description.trim() : "", secret]
    .filter(Boolean)
    .join("\n\n");
  if (!text) return "";
  const lines = text.replaceAll("*/", "*\\/").trim().split("\n");
  if (lines.length === 1) return `${indent}/** ${lines[0]} */\n`;
  return `${indent}/**\n${lines.map((line) => `${indent} *${line ? ` ${line}` : ""}`).join("\n")}\n${indent} */\n`;
}

export function renderType(schema: JsonSchema, types: Record<string, JsonSchema>, where: string, indent = ""): string {
  if (schema === true) return "unknown";
  if (schema === false) return "never";
  checkKeywords(schema, where);
  const parts: string[] = [];
  if (typeof schema.$ref === "string") parts.push(refName(schema.$ref, types, where));
  if (schema.const !== undefined) {
    if (!isPrimitive(schema.const)) throw new IrError(`${where}: const must be a primitive`);
    parts.push(JSON.stringify(schema.const));
  }
  if (schema.enum !== undefined) {
    if (!Array.isArray(schema.enum) || !schema.enum.every(isPrimitive)) {
      throw new IrError(`${where}: enum must be an array of primitives`);
    }
    parts.push(schema.enum.map((value) => JSON.stringify(value)).join(" | "));
  }
  for (const keyword of ["anyOf", "oneOf"] as const) {
    if (schema[keyword] !== undefined) {
      const branches = schemaList(schema[keyword], keyword, where).map((branch, index) =>
        renderType(branch, types, `${where}.${keyword}[${index}]`, indent),
      );
      parts.push(`(${branches.join(" | ")})`);
    }
  }
  if (schema.allOf !== undefined) {
    const branches = schemaList(schema.allOf, "allOf", where).map((branch, index) =>
      renderType(branch, types, `${where}.allOf[${index}]`, indent),
    );
    parts.push(`(${branches.join(" & ")})`);
  }
  const list = typeList(schema, where);
  if (list) {
    // Literal keywords (enum/const/$ref) already constrain the value; `type` alongside them adds nothing to the TS type.
    if (parts.length === 0 || schema.anyOf || schema.oneOf || schema.allOf) {
      const union = list.map((name) => renderTypeName(name, schema, types, where, indent)).join(" | ");
      parts.push(list.length > 1 ? `(${union})` : union);
    }
  } else if (schema.properties !== undefined || schema.additionalProperties !== undefined) {
    parts.push(renderTypeName("object", schema, types, where, indent));
  } else if (schema.items !== undefined) {
    parts.push(renderTypeName("array", schema, types, where, indent));
  }
  if (parts.length === 0) return "unknown";
  return parts.length === 1 ? parts[0] : parts.map((part) => `(${part})`).join(" & ");
}

function renderTypeName(
  name: string,
  schema: SchemaObject,
  types: Record<string, JsonSchema>,
  where: string,
  indent: string,
): string {
  switch (name) {
    case "string":
      return "string";
    case "integer":
    case "number":
      return "number";
    case "boolean":
      return "boolean";
    case "null":
      return "null";
    case "array": {
      if (schema.items === undefined) return "unknown[]";
      const item = renderType(schema.items as JsonSchema, types, `${where}.items`, indent);
      return /^[A-Za-z0-9_]+$/.test(item) ? `${item}[]` : `Array<${item}>`;
    }
    default:
      return renderObjectType(schema, types, where, indent);
  }
}

function renderObjectType(
  schema: SchemaObject,
  types: Record<string, JsonSchema>,
  where: string,
  indent: string,
): string {
  const properties = (schema.properties ?? {}) as Record<string, JsonSchema>;
  const required = new Set((schema.required ?? []) as string[]);
  const inner = `${indent}  `;
  const lines = Object.entries(properties).map(([key, value]) => {
    const optional = required.has(key) ? "" : "?";
    const doc = docComment(value, inner);
    return `${doc}${inner}${propertyKey(key)}${optional}: ${renderType(value, types, `${where}.properties.${key}`, inner)};`;
  });
  const extra = schema.additionalProperties;
  let base = lines.length > 0 ? `{\n${lines.join("\n")}\n${indent}}` : null;
  if (extra === undefined || extra === true) {
    const open = "Record<string, unknown>";
    return base ? `${base} & ${open}` : open;
  }
  if (extra === false) return base ?? "Record<string, never>";
  const value = renderType(extra as JsonSchema, types, `${where}.additionalProperties`, indent);
  const map = `Record<string, ${value}>`;
  base = base ? `${base} & ${map}` : map;
  return base;
}

// Validators
//
// Every compiled check reads a plain identifier, so TypeScript narrowing (typeof, Array.isArray,
// the isObject guard) types the keyword checks without casts.

export class ValidatorBuilder {
  private readonly types: Record<string, JsonSchema>;
  private counter = 0;
  /** Hoisted constants (Sets of known keys, enum lists, regexps). */
  readonly constants: string[] = [];
  usesIsObject = false;

  constructor(types: Record<string, JsonSchema>) {
    this.types = types;
  }

  private fresh(prefix: string): string {
    this.counter += 1;
    return `${prefix}${this.counter}`;
  }

  /** Statements that push issues into `errs` for identifier `value` at runtime path expression `path`. */
  compile(schema: JsonSchema, value: string, path: string, errs: string, where: string, indent: string): string {
    if (schema === true) return "";
    if (schema === false) return `${indent}${errs}.push({ path: ${path}, message: "no value is allowed here" });\n`;
    checkKeywords(schema, where);
    let out = "";
    if (typeof schema.$ref === "string") {
      out += `${indent}check${refName(schema.$ref, this.types, where)}(${value}, ${path}, ${errs});\n`;
    }
    const list = typeList(schema, where);
    if (!list) return out + this.compileKeywords(schema, null, value, path, errs, where, indent);
    const inner = `${indent}  `;
    const body = this.compileKeywords(schema, list, value, path, errs, where, inner);
    const conditions = list.map((name) => this.typeCondition(name, value));
    out += `${indent}if (!(${conditions.join(" || ")})) {\n`;
    out += `${inner}${errs}.push({ path: ${path}, message: ${JSON.stringify(`expected ${list.join(" or ")}`)} });\n`;
    out += body ? `${indent}} else {\n${body}${indent}}\n` : `${indent}}\n`;
    return out;
  }

  private typeCondition(name: string, value: string): string {
    switch (name) {
      case "string":
        return `typeof ${value} === "string"`;
      case "integer":
        return `(typeof ${value} === "number" && Number.isInteger(${value}))`;
      case "number":
        return `(typeof ${value} === "number" && Number.isFinite(${value}))`;
      case "boolean":
        return `typeof ${value} === "boolean"`;
      case "null":
        return `${value} === null`;
      case "array":
        return `Array.isArray(${value})`;
      default:
        this.usesIsObject = true;
        return `isObject(${value})`;
    }
  }

  private compileKeywords(
    schema: SchemaObject,
    list: string[] | null,
    value: string,
    path: string,
    errs: string,
    where: string,
    indent: string,
  ): string {
    let out = "";
    const push = (message: string) => `${errs}.push({ path: ${path}, message: ${message} });`;
    if (schema.const !== undefined) {
      if (!isPrimitive(schema.const)) throw new IrError(`${where}: const must be a primitive`);
      const literal = JSON.stringify(schema.const);
      out += `${indent}if (${value} !== ${literal}) ${push(JSON.stringify(`expected ${literal}`))}\n`;
    }
    if (schema.enum !== undefined) {
      if (!Array.isArray(schema.enum) || !schema.enum.every(isPrimitive)) {
        throw new IrError(`${where}: enum must be an array of primitives`);
      }
      const name = this.fresh("ENUM_");
      this.constants.push(`const ${name}: ReadonlyArray<unknown> = ${JSON.stringify(schema.enum)};`);
      out += `${indent}if (!${name}.includes(${value})) ${push(JSON.stringify(`expected one of ${JSON.stringify(schema.enum)}`))}\n`;
    }
    for (const keyword of ["anyOf", "oneOf"] as const) {
      if (schema[keyword] === undefined) continue;
      const branches = schemaList(schema[keyword], keyword, where);
      const matched = this.fresh("matched");
      out += `${indent}let ${matched} = 0;\n`;
      branches.forEach((branch, index) => {
        const branchErrs = this.fresh("branch");
        out += `${indent}const ${branchErrs}: ValidationIssue[] = [];\n`;
        out += this.compile(branch, value, path, branchErrs, `${where}.${keyword}[${index}]`, indent);
        out += `${indent}if (${branchErrs}.length === 0) ${matched} += 1;\n`;
      });
      const condition = keyword === "anyOf" ? `${matched} === 0` : `${matched} !== 1`;
      const message =
        keyword === "anyOf"
          ? JSON.stringify(`did not match any of ${branches.length} schemas`)
          : `\`matched \${${matched}} of ${branches.length} schemas, expected exactly one\``;
      out += `${indent}if (${condition}) ${push(message)}\n`;
    }
    if (schema.allOf !== undefined) {
      schemaList(schema.allOf, "allOf", where).forEach((branch, index) => {
        out += this.compile(branch, value, path, errs, `${where}.allOf[${index}]`, indent);
      });
    }
    // With exactly one declared type the caller's else-branch already narrowed `value`.
    const single = list !== null && list.length === 1 ? list[0] : null;
    const section = (types: string[], condition: string, build: (at: string) => string) => {
      if (single !== null) return types.includes(single) ? build(indent) : "";
      if (list !== null && !list.some((name) => types.includes(name))) return "";
      const body = build(`${indent}  `);
      return body ? `${indent}if (${condition}) {\n${body}${indent}}\n` : "";
    };
    out += section(["string"], `typeof ${value} === "string"`, (at) =>
      this.stringKeywords(schema, value, path, errs, where, at),
    );
    out += section(["integer", "number"], `typeof ${value} === "number"`, (at) =>
      this.numberKeywords(schema, value, path, errs, where, at),
    );
    out += section(["array"], `Array.isArray(${value})`, (at) =>
      this.arrayKeywords(schema, value, path, errs, where, at),
    );
    const objectSection = section(["object"], `isObject(${value})`, (at) =>
      this.objectKeywords(schema, value, path, errs, where, at),
    );
    if (objectSection && single === null) this.usesIsObject = true;
    out += objectSection;
    return out;
  }

  private stringKeywords(
    schema: SchemaObject,
    value: string,
    path: string,
    errs: string,
    where: string,
    indent: string,
  ): string {
    const push = (message: string) => `${errs}.push({ path: ${path}, message: ${message} });`;
    let out = "";
    if (schema.minLength !== undefined || schema.maxLength !== undefined) {
      const len = this.fresh("len");
      out += `${indent}const ${len} = Array.from(${value}).length; // JSON Schema counts code points\n`;
      if (typeof schema.minLength === "number") {
        out += `${indent}if (${len} < ${schema.minLength}) ${push(JSON.stringify(`shorter than ${schema.minLength}`))}\n`;
      }
      if (typeof schema.maxLength === "number") {
        out += `${indent}if (${len} > ${schema.maxLength}) ${push(JSON.stringify(`longer than ${schema.maxLength}`))}\n`;
      }
    }
    if (schema.pattern !== undefined) {
      if (typeof schema.pattern !== "string") throw new IrError(`${where}: pattern must be a string`);
      checkPortablePattern(schema.pattern, where);
      try {
        new RegExp(schema.pattern, "u");
      } catch {
        throw new IrError(`${where}: pattern is not a valid regular expression`);
      }
      const name = this.fresh("PATTERN_");
      this.constants.push(`const ${name} = new RegExp(${JSON.stringify(schema.pattern)}, "u");`);
      out += `${indent}if (!${name}.test(${value})) ${push(JSON.stringify(`does not match ${schema.pattern}`))}\n`;
    }
    return out;
  }

  private numberKeywords(
    schema: SchemaObject,
    value: string,
    path: string,
    errs: string,
    where: string,
    indent: string,
  ): string {
    const push = (message: string) => `${errs}.push({ path: ${path}, message: ${message} });`;
    let out = "";
    const bound = (keyword: string, op: string, label: string) => {
      const limit = schema[keyword];
      if (limit === undefined) return;
      if (typeof limit !== "number") throw new IrError(`${where}: ${keyword} must be a number`);
      out += `${indent}if (${value} ${op} ${limit}) ${push(JSON.stringify(`${label} ${limit}`))}\n`;
    };
    bound("minimum", "<", "less than");
    bound("maximum", ">", "greater than");
    bound("exclusiveMinimum", "<=", "not greater than");
    bound("exclusiveMaximum", ">=", "not less than");
    if (schema.format !== undefined) {
      if (typeof schema.format !== "string") throw new IrError(`${where}: format must be a string`);
      const range = INTEGER_FORMATS[schema.format];
      // Other formats (double, date-time, uri, ...) are annotations here.
      if (range) {
        out += `${indent}if (!Number.isInteger(${value}) || ${value} < ${range[0]} || ${value} > ${range[1]}) ${push(JSON.stringify(`not a valid ${schema.format}`))}\n`;
      }
    }
    return out;
  }

  private arrayKeywords(
    schema: SchemaObject,
    value: string,
    path: string,
    errs: string,
    where: string,
    indent: string,
  ): string {
    const push = (message: string) => `${errs}.push({ path: ${path}, message: ${message} });`;
    let out = "";
    if (typeof schema.minItems === "number") {
      out += `${indent}if (${value}.length < ${schema.minItems}) ${push(JSON.stringify(`fewer than ${schema.minItems} items`))}\n`;
    }
    if (typeof schema.maxItems === "number") {
      out += `${indent}if (${value}.length > ${schema.maxItems}) ${push(JSON.stringify(`more than ${schema.maxItems} items`))}\n`;
    }
    if (schema.items !== undefined && schema.items !== true) {
      if (Array.isArray(schema.items)) throw new IrError(`${where}: tuple items are outside the supported subset`);
      const index = this.fresh("i");
      const item = this.fresh("item");
      const body = this.compile(
        schema.items as JsonSchema,
        item,
        `${path} + "/" + ${index}`,
        errs,
        `${where}.items`,
        `${indent}  `,
      );
      out += `${indent}for (let ${index} = 0; ${index} < ${value}.length; ${index} += 1) {\n`;
      out += `${indent}  const ${item}: unknown = ${value}[${index}];\n${body}`;
      out += `${indent}}\n`;
    }
    return out;
  }

  private objectKeywords(
    schema: SchemaObject,
    value: string,
    path: string,
    errs: string,
    where: string,
    indent: string,
  ): string {
    if (schema.properties === undefined && schema.required === undefined && schema.additionalProperties === undefined) {
      return "";
    }
    const push = (message: string) => `${errs}.push({ path: ${path}, message: ${message} });`;
    const properties = schema.properties ?? {};
    if (typeof properties !== "object" || properties === null || Array.isArray(properties)) {
      throw new IrError(`${where}: properties must be an object`);
    }
    const required = schema.required ?? [];
    if (!Array.isArray(required) || !required.every((key) => typeof key === "string")) {
      throw new IrError(`${where}: required must be an array of strings`);
    }
    let out = "";
    for (const key of required as string[]) {
      out += `${indent}if (!Object.hasOwn(${value}, ${JSON.stringify(key)})) ${push(JSON.stringify(`missing required property ${JSON.stringify(key)}`))}\n`;
    }
    for (const [key, propSchema] of Object.entries(properties as Record<string, JsonSchema>)) {
      const prop = this.fresh("prop");
      const body = this.compile(
        propSchema,
        prop,
        `${path} + ${JSON.stringify(`/${pointerEscape(key)}`)}`,
        errs,
        `${where}.properties.${key}`,
        `${indent}  `,
      );
      if (!body) continue;
      out += `${indent}if (Object.hasOwn(${value}, ${JSON.stringify(key)})) {\n`;
      out += `${indent}  const ${prop}: unknown = ${value}[${JSON.stringify(key)}];\n${body}${indent}}\n`;
    }
    const extra = schema.additionalProperties;
    if (extra !== undefined && extra !== true) {
      const known = this.fresh("KNOWN_");
      this.constants.push(`const ${known}: ReadonlySet<string> = new Set(${JSON.stringify(Object.keys(properties))});`);
      const key = this.fresh("key");
      out += `${indent}for (const ${key} of Object.keys(${value})) {\n`;
      out += `${indent}  if (${known}.has(${key})) continue;\n`;
      if (extra === false) {
        out += `${indent}  ${errs}.push({ path: ${path}, message: \`unexpected property \${JSON.stringify(${key})}\` });\n`;
      } else {
        const item = this.fresh("extra");
        out += `${indent}  const ${item}: unknown = ${value}[${key}];\n`;
        out += this.compile(
          extra as JsonSchema,
          item,
          `${path} + "/" + ${key}.replaceAll("~", "~0").replaceAll("/", "~1")`,
          errs,
          `${where}.additionalProperties`,
          `${indent}  `,
        );
      }
      out += `${indent}}\n`;
    }
    return out;
  }
}

function pointerEscape(key: string): string {
  return key.replaceAll("~", "~0").replaceAll("/", "~1");
}
