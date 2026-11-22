// A small JSON Schema 2020-12 subset validator: exactly the keywords
// cmux-app.schema.json uses. Zero dependencies so `cmux app validate`, the
// registry and tests run offline and give identical results.

export interface SchemaError {
  /** JSON pointer of the offending value ("" is the document root). */
  path: string
  code: string
  message: string
}

type Schema = Record<string, unknown> | boolean
type Json = unknown

const pointer = (base: string, key: string | number) => `${base}/${String(key).replace(/~/g, "~0").replace(/\//g, "~1")}`

const typeOf = (v: Json): string => {
  if (v === null) return "null"
  if (Array.isArray(v)) return "array"
  if (typeof v === "number") return Number.isInteger(v) ? "integer" : "number"
  return typeof v
}

const typeMatches = (v: Json, t: string) => {
  const actual = typeOf(v)
  return actual === t || (t === "number" && actual === "integer")
}

const deepEqual = (a: Json, b: Json): boolean => JSON.stringify(a) === JSON.stringify(b)

export class SchemaValidator {
  private readonly regexCache = new Map<string, RegExp>()

  constructor(private readonly root: Record<string, unknown>) {}

  validate(value: Json): SchemaError[] {
    const errors: SchemaError[] = []
    this.check(this.root, value, "", errors)
    return errors
  }

  private resolve(ref: string): Schema {
    if (!ref.startsWith("#/")) throw new Error(`unsupported $ref ${ref}`)
    let node: unknown = this.root
    for (const part of ref.slice(2).split("/")) node = (node as Record<string, unknown>)[part]
    if (node === undefined) throw new Error(`unresolved $ref ${ref}`)
    return node as Schema
  }

  private regex(source: string): RegExp {
    let r = this.regexCache.get(source)
    if (!r) {
      r = new RegExp(source, "u")
      this.regexCache.set(source, r)
    }
    return r
  }

  private check(schema: Schema, v: Json, path: string, errors: SchemaError[]): void {
    if (schema === true) return
    if (schema === false) {
      errors.push({ path, code: "schema.false", message: "value is not allowed here" })
      return
    }
    const s = schema
    if (typeof s.$ref === "string") this.check(this.resolve(s.$ref), v, path, errors)
    if ("const" in s && !deepEqual(v, s.const)) errors.push({ path, code: "const", message: `must be ${JSON.stringify(s.const)}` })
    if (Array.isArray(s.enum) && !s.enum.some((e) => deepEqual(e, v))) {
      errors.push({ path, code: "enum", message: `must be one of ${s.enum.map((e) => JSON.stringify(e)).join(", ")}` })
    }
    if (typeof s.type === "string" && !typeMatches(v, s.type)) {
      errors.push({ path, code: "type", message: `must be ${s.type}, got ${typeOf(v)}` })
      return
    }
    if (Array.isArray(s.allOf)) for (const sub of s.allOf) this.check(sub as Schema, v, path, errors)
    if (s.if !== undefined) {
      const probe: SchemaError[] = []
      this.check(s.if as Schema, v, path, probe)
      if (probe.length === 0 && s.then !== undefined) this.check(s.then as Schema, v, path, errors)
      if (probe.length > 0 && s.else !== undefined) this.check(s.else as Schema, v, path, errors)
    }
    if (Array.isArray(s.oneOf)) {
      const passing = s.oneOf.filter((sub) => {
        const e: SchemaError[] = []
        this.check(sub as Schema, v, path, e)
        return e.length === 0
      }).length
      if (passing !== 1) {
        // Report the closest branch's errors when none matched: that is what the author meant most often.
        if (passing === 0) {
          const branches = s.oneOf.map((sub) => {
            const e: SchemaError[] = []
            this.check(sub as Schema, v, path, e)
            return e
          })
          const best = branches.reduce((a, b) => (b.length < a.length ? b : a))
          errors.push(...best)
          if (best.length === 0) errors.push({ path, code: "oneOf", message: "must match exactly one alternative" })
        } else {
          errors.push({ path, code: "oneOf", message: "matches more than one alternative" })
        }
      }
    }
    if (typeof v === "string") this.checkString(s, v, path, errors)
    if (typeof v === "number") this.checkNumber(s, v, path, errors)
    if (Array.isArray(v)) this.checkArray(s, v, path, errors)
    else if (v !== null && typeof v === "object") this.checkObject(s, v as Record<string, Json>, path, errors)
  }

  private checkString(s: Record<string, unknown>, v: string, path: string, errors: SchemaError[]) {
    const length = [...v].length
    if (typeof s.minLength === "number" && length < s.minLength) errors.push({ path, code: "minLength", message: `must have at least ${s.minLength} characters` })
    if (typeof s.maxLength === "number" && length > s.maxLength) errors.push({ path, code: "maxLength", message: `must have at most ${s.maxLength} characters` })
    if (typeof s.pattern === "string" && !this.regex(s.pattern).test(v)) errors.push({ path, code: "pattern", message: `must match ${s.pattern}` })
  }

  private checkNumber(s: Record<string, unknown>, v: number, path: string, errors: SchemaError[]) {
    if (typeof s.minimum === "number" && v < s.minimum) errors.push({ path, code: "minimum", message: `must be >= ${s.minimum}` })
    if (typeof s.maximum === "number" && v > s.maximum) errors.push({ path, code: "maximum", message: `must be <= ${s.maximum}` })
  }

  private checkArray(s: Record<string, unknown>, v: Json[], path: string, errors: SchemaError[]) {
    if (typeof s.minItems === "number" && v.length < s.minItems) errors.push({ path, code: "minItems", message: `must have at least ${s.minItems} items` })
    if (typeof s.maxItems === "number" && v.length > s.maxItems) errors.push({ path, code: "maxItems", message: `must have at most ${s.maxItems} items` })
    if (s.uniqueItems === true && new Set(v.map((x) => JSON.stringify(x))).size !== v.length) errors.push({ path, code: "uniqueItems", message: "items must be unique" })
    if (s.items !== undefined) v.forEach((item, i) => this.check(s.items as Schema, item, pointer(path, i), errors))
  }

  private checkObject(s: Record<string, unknown>, v: Record<string, Json>, path: string, errors: SchemaError[]) {
    const keys = Object.keys(v)
    if (typeof s.minProperties === "number" && keys.length < s.minProperties) errors.push({ path, code: "minProperties", message: `must have at least ${s.minProperties} properties` })
    if (typeof s.maxProperties === "number" && keys.length > s.maxProperties) errors.push({ path, code: "maxProperties", message: `must have at most ${s.maxProperties} properties` })
    if (Array.isArray(s.required)) {
      for (const key of s.required as string[]) if (!(key in v)) errors.push({ path: pointer(path, key), code: "required", message: `${key} is required` })
    }
    const props = (s.properties ?? {}) as Record<string, Schema>
    for (const key of keys) {
      if (s.propertyNames !== undefined) {
        const e: SchemaError[] = []
        this.check(s.propertyNames as Schema, key, pointer(path, key), e)
        if (e.length) errors.push({ path: pointer(path, key), code: "propertyName", message: `key ${JSON.stringify(key)} is not allowed: ${e[0]!.message}` })
      }
      if (key in props) this.check(props[key]!, v[key], pointer(path, key), errors)
      else if (s.additionalProperties === false) errors.push({ path: pointer(path, key), code: "additionalProperties", message: `unknown key ${JSON.stringify(key)}` })
      else if (s.additionalProperties !== undefined && s.additionalProperties !== true) this.check(s.additionalProperties as Schema, v[key], pointer(path, key), errors)
    }
  }
}
