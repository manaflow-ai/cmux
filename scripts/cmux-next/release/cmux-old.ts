/**
 * cmux-old client replay (compat gate, plans/cmux-next/release-rails.md). The shipped cmux app makes
 * every Cloud call itself, so instead of running it this replays the requests its source builds.
 *
 *   bun cmux-old.ts generate --tag vX.Y.Z [--repo DIR] [--out FILE]
 *       Reads every "/api/..." request the tag's shipped Swift builds, from the source alone (no
 *       network, deterministic): the method from the enclosing call, its helper or its function, the
 *       path template, the header names the client sets, the JSON body keys and, for reads, the
 *       response shape the client's decoder needs (a Decodable struct, parsed; or a reviewed entry in
 *       cmux-old/<tag>.review.json for a hand-written dictionary decoder). Every "/api/" literal must
 *       resolve to requests or be skipped with a reason in the review file; anything else fails.
 *       Also records how the tag signs in to Stack (project, publishable key, path) from its source.
 *       Writes cmux-old/<tag>.json.
 *   bun cmux-old.ts replay --change KEY [--spec FILE] [--origin https://cmux-staging.vercel.app]
 *       [--credentials FILE|-] [--unauthenticated] [--revisions-json JSON]   (CMUX_RELEASE_AGENT_CREDENTIALS=FILE also names the file)
 *       Signs in as the AGENT test profile (CMUX_UITEST_STACK_EMAIL/_PASSWORD from the environment or
 *       the credentials file, default ~/.secrets/cmuxterm-dev.env; values never printed) the way the
 *       tag does, replays every read with the client's headers and checks status and response shape,
 *       probes every other request unauthenticated (shape-only: route present, auth layer intact),
 *       signs out, compares the staging and production web revisions, and writes a compat-smoke receipt.
 *   bun cmux-old.ts revisions
 *       Prints the staging and production web revisions (Vercel deployment metadata, read-only).
 *
 * Production steps refuse when the latest stable release is newer than the replayed spec, when the
 * replay was not authenticated, or when staging runs an older web revision than production (compat.ts).
 * Not covered: the real binary on an isolated cloud Mac (a follow-up bead).
 */
import { execFileSync, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { actor, receiptsDir, runIdOf, summaryLine, writeReceipt } from "./receipts.ts"
import { REPO_ROOT } from "./trees.ts"

// ---------------------------------------------------------------- shapes

/**
 * What a client decoder needs from a JSON value. A string names a type ("string", "number",
 * "integer", "boolean", "object" for any JSON object, "any" for anything present); an array holds
 * the element shape; an object lists keys, a key ending in "?" is optional (absent or null), and
 * "a|b" accepts either name (the decoder reads the first one present).
 */
export type Shape = string | ReadonlyArray<Shape> | { readonly [key: string]: Shape }

/** Everything `value` lacks that `shape` needs; empty when a decoder built from `shape` would succeed. */
export const shapeProblems = (shape: Shape, value: unknown, at = "$", out: Array<string> = []): Array<string> => {
  if (Array.isArray(shape)) {
    if (!Array.isArray(value)) out.push(`${at}: expected an array, got ${kindOf(value)}`)
    else for (const [i, v] of value.slice(0, 50).entries()) shapeProblems(shape[0] ?? "any", v, `${at}[${i}]`, out)
    return out
  }
  if (typeof shape === "object") {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      out.push(`${at}: expected an object, got ${kindOf(value)}`)
      return out
    }
    for (const [rawKey, inner] of Object.entries(shape)) {
      const optional = rawKey.endsWith("?")
      const names = (optional ? rawKey.slice(0, -1) : rawKey).split("|")
      const obj = value as Record<string, unknown>
      const key = names.find((n) => obj[n] !== undefined && obj[n] !== null) ?? names.join("|")
      const v = obj[key]
      if (v === undefined || v === null) {
        if (!optional) out.push(`${at}.${key}: missing (the decoder requires it)`)
        continue
      }
      shapeProblems(inner, v, `${at}.${key}`, out)
    }
    return out
  }
  const ok =
    shape === "any" ? value !== undefined && value !== null
    : shape === "object" ? !!value && typeof value === "object" && !Array.isArray(value)
    : shape === "integer" ? Number.isInteger(value)
    : shape === "number" ? typeof value === "number"
    : shape === "string" ? typeof value === "string"
    : shape === "boolean" ? typeof value === "boolean"
    : false
  if (!ok) out.push(`${at}: expected ${shape}, got ${kindOf(value)}`)
  return out
}

const kindOf = (v: unknown) => (v === null ? "null" : Array.isArray(v) ? "array" : typeof v)

// ---------------------------------------------------------------- Swift scanning

/** The source with comments and string contents blanked (same length, quotes kept): brackets in it are code. */
export const maskSwift = (src: string): string => {
  const out = src.split("")
  let i = 0
  const blank = (from: number, to: number) => {
    for (let k = from; k < to; k++) if (out[k] !== "\n") out[k] = " "
  }
  while (i < src.length) {
    const c = src[i]
    if (c === "/" && src[i + 1] === "/") {
      const end = src.indexOf("\n", i)
      const stop = end < 0 ? src.length : end
      blank(i, stop)
      i = stop
    } else if (c === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2)
      const stop = end < 0 ? src.length : end + 2
      blank(i, stop)
      i = stop
    } else if (c === '"') {
      const triple = src.startsWith('"""', i)
      const quote = triple ? '"""' : '"'
      let j = i + quote.length
      let depth = 0
      for (; j < src.length; j++) {
        if (depth === 0 && src.startsWith(quote, j)) break
        if (src[j] === "\\" && depth === 0) {
          if (src[j + 1] === "(") {
            depth = 1
            j++
          } else j++
        } else if (depth > 0) {
          if (src[j] === "(") depth++
          else if (src[j] === ")") depth--
        } else if (!triple && src[j] === "\n") break
      }
      blank(i + quote.length, j)
      i = j + quote.length
    } else i++
  }
  return out.join("")
}

const OPEN: Record<string, string> = { "(": ")", "[": "]", "{": "}" }
const CLOSE: Record<string, string> = { ")": "(", "]": "[", "}": "{" }

/** The nearest bracket that is open at `pos`, scanning back through masked code. */
const openerBefore = (masked: string, pos: number): number => {
  const stack: Array<string> = []
  for (let i = pos - 1; i >= 0; i--) {
    const c = masked[i]!
    if (CLOSE[c]) stack.push(c)
    else if (OPEN[c]) {
      if (stack.length && CLOSE[stack.at(-1)!] === c) stack.pop()
      else return i
    }
  }
  return -1
}

const closerOf = (masked: string, open: number): number => {
  let depth = 0
  for (let i = open; i < masked.length; i++) {
    const c = masked[i]!
    if (OPEN[c]) depth++
    else if (CLOSE[c] && --depth === 0) return i
  }
  return masked.length
}

interface Call {
  readonly callee: string
  readonly open: number
  readonly close: number
  readonly args: ReadonlyArray<{ readonly label?: string; readonly value: string }>
}

/** The call whose argument list holds `pos` directly (not inside a nested [ or {). */
const enclosingCall = (src: string, masked: string, pos: number): Call | undefined => {
  const open = openerBefore(masked, pos)
  if (open < 0 || masked[open] !== "(") return undefined
  const callee = masked.slice(0, open).match(/([A-Za-z_][\w.]*)\s*$/)?.[1]?.split(".").at(-1)
  if (!callee || /^(if|guard|while|switch|case|return|for)$/.test(callee)) return undefined
  const close = closerOf(masked, open)
  const args: Array<{ label?: string; value: string }> = []
  let depth = 0
  let start = open + 1
  const push = (end: number) => {
    const text = src.slice(start, end).trim()
    if (!text) return
    const m = text.match(/^([A-Za-z_]\w*)\s*:\s*([\s\S]*)$/)
    const maskedText = masked.slice(start, end).trim()
    if (m && /^[A-Za-z_]\w*\s*:/.test(maskedText)) args.push({ label: m[1]!, value: m[2]!.trim() })
    else args.push({ value: text })
  }
  for (let i = open + 1; i < close; i++) {
    const c = masked[i]!
    if (OPEN[c]) depth++
    else if (CLOSE[c]) depth--
    else if (c === "," && depth === 0) {
      push(i)
      start = i + 1
    }
  }
  push(close)
  return { callee, open, close, args }
}

interface Func {
  readonly name: string
  readonly start: number
  readonly end: number
  readonly body: string
}

/** The innermost `func` (or `init`) whose body holds `pos`. */
const enclosingFunc = (src: string, masked: string, pos: number): Func | undefined => {
  let at = pos
  for (;;) {
    const open = openerBefore(masked, at)
    if (open < 0) return undefined
    if (masked[open] === "{") {
      const head = masked.slice(Math.max(0, open - 600), open)
      const lastBoundary = Math.max(head.lastIndexOf("}"), head.lastIndexOf("{"))
      const decl = head.slice(lastBoundary + 1)
      const m = decl.match(/\bfunc\s+([A-Za-z_]\w*)|\b(init)\s*[?(]/)
      if (m) {
        const end = closerOf(masked, open)
        return { name: m[1] ?? m[2]!, start: open, end, body: src.slice(open, end + 1) }
      }
    }
    at = open
  }
}

const funcDefs = (src: string, masked: string, name: string): Array<Func> => {
  const out: Array<Func> = []
  for (const m of masked.matchAll(new RegExp(`\\bfunc\\s+${name}\\s*[(<]`, "g"))) {
    const open = masked.indexOf("{", m.index)
    if (open < 0) continue
    const end = closerOf(masked, open)
    out.push({ name, start: open, end, body: src.slice(open, end + 1) })
  }
  return out
}

const METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"] as const
const methodLiteral = (value: string): string | undefined => {
  const m = value.match(/^"(GET|POST|PUT|PATCH|DELETE)"$/) ?? value.match(/^\.(get|post|put|patch|delete)$/)
  return m ? m[1]!.toUpperCase() : undefined
}
/** Methods a body assigns to `httpMethod` as literals (a ternary yields both). */
const assignedMethods = (body: string): Set<string> => new Set([...body.matchAll(/\.httpMethod\s*=\s*([^\n]+)/g)].flatMap((m) => [...m[1]!.matchAll(/"(GET|POST|PUT|PATCH|DELETE)"/g)].map((l) => l[1]!)))
/** `httpMethod = someVariable`: the method comes from a caller. */
const setsMethodFromVariable = (body: string) => [...body.matchAll(/\.httpMethod\s*=\s*([^\n]+)/g)].some((m) => !/"(GET|POST|PUT|PATCH|DELETE)"/.test(m[1]!))
/** Literal methods a helper passes on to another request call (`request("POST", path: path, ...)`). */
const forwardedMethods = (body: string): Set<string> => new Set([...body.matchAll(/\b[A-Za-z_]\w*\(\s*"(GET|POST|PUT|PATCH|DELETE)"\s*,/g)].map((m) => m[1]!))

/** Header names a request builder sets (`setValue(x, forHTTPHeaderField: "Name")`), not ones it reads. */
const setHeaders = (body: string): Array<string> => [...body.matchAll(/\b(?:setValue|addValue)\(\s*(?!nil\b)[^\n]*?forHTTPHeaderField:\s*"([^"]+)"/g)].map((m) => m[1]!)

/**
 * The query a request always carries: the literal's own `?a=b` (literal pairs only), else literal
 * `URLQueryItem(name: "a", value: "b")` assignments to `queryItems` in the function that builds it.
 */
const literalQuery = (literal: string, body: string | undefined): string | undefined => {
  const own = literal.includes("?") ? literal.slice(literal.indexOf("?") + 1) : ""
  if (own && !own.includes("\\(")) return own
  const items = body?.match(/\.queryItems\s*=\s*\[([^\]]*)\]/)?.[1]
  if (!items) return undefined
  const pairs = [...items.matchAll(/URLQueryItem\(\s*name:\s*"([^"]+)"\s*,\s*value:\s*"([^"]*)"\s*\)/g)].map((m) => `${encodeURIComponent(m[1]!)}=${encodeURIComponent(m[2]!)}`)
  return pairs.length && pairs.length === (items.match(/URLQueryItem\(/g) ?? []).length ? pairs.join("&") : undefined
}

/** Not request helpers: the path is only part of a URL here; the function that holds it decides. */
const URL_BUILDERS = new Set(["URL", "URLComponents", "appendingPathComponent", "appending", "String", "URLRequest"])

/** A Swift path literal as a template: each `\(...)` becomes `{name}` (its last identifier), the query is dropped. */
export const pathTemplate = (literal: string): { path: string; params: Array<string> } => {
  let out = ""
  const params: Array<string> = []
  for (let i = 0; i < literal.length; i++) {
    if (literal[i] === "\\" && literal[i + 1] === "(") {
      let depth = 0
      let j = i + 1
      for (; j < literal.length; j++) {
        if (literal[j] === "(") depth++
        else if (literal[j] === ")" && --depth === 0) break
      }
      const idents = [...literal.slice(i + 2, j).matchAll(/[A-Za-z_]\w*/g)].map((m) => m[0]).filter((w) => !/^(try|Self|self|pathSegment|addingPercentEncoding|withAllowedCharacters|urlPathAllowed|encode)$/.test(w))
      const name = idents.at(-1) ?? "param"
      params.push(name)
      out += `{${name}}`
      i = j
    } else out += literal[i]
  }
  return { path: out.split("?")[0]!.replace(/\/+$/, "") || "/", params }
}

// ---------------------------------------------------------------- Decodable structs

/** The Swift source a type lookup searches, nearest first. */
export interface SourceScope {
  readonly func?: string
  readonly file: string
  /** Other shipped files, nearest package first: [path, source]. */
  readonly others: () => Iterable<[string, string]>
}

const PRIMITIVE: Record<string, string> = {
  String: "string", Substring: "string", Character: "string", Date: "string", URL: "string", UUID: "string", Data: "string", Decimal: "number",
  Int: "integer", Int8: "integer", Int16: "integer", Int32: "integer", Int64: "integer", UInt: "integer", UInt8: "integer", UInt16: "integer", UInt32: "integer", UInt64: "integer",
  Double: "number", Float: "number", CGFloat: "number", TimeInterval: "number", Bool: "boolean",
}

const maskCache = new Map<string, string>()
const findTypeDecl = (scope: SourceScope, name: string): { text: string; masked: string; open: number; kind: string; header: string; file: string } | undefined => {
  const re = new RegExp(`\\b(struct|enum|class)\\s+${name}\\b([^{]*)\\{`)
  const candidates: Array<[string, string]> = [...(scope.func ? [["<function>", scope.func] as [string, string]] : []), ["<file>", scope.file], ...scope.others()]
  for (const [file, text] of candidates) {
    if (!re.test(text)) continue
    const masked = maskCache.get(text) ?? maskSwift(text)
    maskCache.set(text, masked)
    const m = masked.match(re)
    if (m && m.index !== undefined) return { text, masked, open: m.index + m[0].length - 1, kind: m[1]!, header: m[2]!, file }
  }
  return undefined
}

/** Top-level declarations of a type body (depth 1 only). */
const topLevel = (masked: string, open: number): Array<{ start: number; end: number }> => {
  const close = closerOf(masked, open)
  const out: Array<{ start: number; end: number }> = []
  let depth = 0
  let start = open + 1
  for (let i = open + 1; i < close; i++) {
    const c = masked[i]!
    if (OPEN[c]) depth++
    else if (CLOSE[c]) {
      depth--
      if (depth === 0 && c === "}") {
        out.push({ start, end: i + 1 })
        start = i + 1
      }
    } else if (c === "\n" && depth === 0) {
      out.push({ start, end: i })
      start = i + 1
    }
  }
  out.push({ start, end: close })
  return out
}

/** The decode shape of Swift type `type` (`[T]`, `T?`, primitives, Decodable structs, raw enums). */
export const typeShape = (type: string, scope: SourceScope, depth = 0, notes: Array<string> = []): { shape: Shape; optional: boolean } => {
  let t = type.trim().replace(/^any\s+/, "")
  let optional = false
  if (t.endsWith("?") || t.endsWith("!")) {
    optional = true
    t = t.slice(0, -1).trim()
  }
  const opt = t.match(/^Optional<(.+)>$/)
  if (opt) {
    optional = true
    t = opt[1]!
  }
  const dict = t.match(/^\[\s*[\w.]+\s*:\s*(.+)\]$/)
  if (dict) return { shape: "object", optional }
  const arr = t.match(/^\[(.+)\]$/) ?? t.match(/^Array<(.+)>$/)
  if (arr) return { shape: [typeShape(arr[1]!, scope, depth, notes).shape], optional }
  const bare = t.split(".").at(-1)!
  if (PRIMITIVE[bare]) return { shape: PRIMITIVE[bare]!, optional }
  if (depth > 5) return { shape: "any", optional }
  return { shape: structShape(bare, scope, depth + 1, notes) ?? "any", optional }
}

/**
 * The keys a synthesized (or simple custom) `Decodable` conformance of `name` reads, or undefined
 * when the type is not found. Custom `init(from:)` bodies are read for `decode`/`decodeIfPresent` calls.
 */
export const structShape = (name: string, scope: SourceScope, depth = 0, notes: Array<string> = []): Shape | undefined => {
  const decl = findTypeDecl(scope, name)
  if (!decl) {
    notes.push(`type ${name} not found in shipped source (decoded as any)`)
    return undefined
  }
  const { text, masked, open } = decl
  if (decl.kind === "enum") {
    if (/:\s*(String|Substring)\b/.test(decl.header)) return "string"
    if (/:\s*(Int|Int64|Int32|UInt)\b/.test(decl.header)) return "integer"
    notes.push(`enum ${name} has no raw type (decoded as any)`)
    return "any"
  }
  const close = closerOf(masked, open)
  const body = text.slice(open, close + 1)
  const bodyMasked = masked.slice(open, close + 1)
  // CodingKeys: property -> JSON key.
  const keys = new Map<string, string>()
  const ck = bodyMasked.match(/\benum\s+CodingKeys\b[^{]*\{/)
  if (ck && ck.index !== undefined) {
    const ckOpen = ck.index + ck[0].length - 1
    const ckBody = body.slice(ckOpen, closerOf(bodyMasked, ckOpen))
    for (const line of ckBody.matchAll(/\bcase\s+([^\n]+)/g)) {
      for (const part of line[1]!.split(",")) {
        const m = part.trim().match(/^([A-Za-z_]\w*)(?:\s*=\s*"([^"]*)")?/)
        if (m) keys.set(m[1]!, m[2] ?? m[1]!)
      }
    }
  }
  const props = new Map<string, string>()
  for (const { start, end } of topLevel(bodyMasked, 0)) {
    const lineMasked = bodyMasked.slice(start, end)
    const line = body.slice(start, end)
    if (/\bstatic\b|\bclass\s+var\b/.test(lineMasked)) continue
    const m = lineMasked.match(/^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|internal|fileprivate|package|nonisolated|lazy)(?:\(set\))?\s+)*(let|var)\s+([A-Za-z_]\w*)\s*:\s*([^={\n]+?)\s*(=|\{|$)/)
    if (!m) continue
    if (m[4] === "{") continue // computed
    if (m[4] === "=" && m[1] === "let") continue // a let with a value is never decoded
    props.set(m[2]!, line.slice(lineMasked.indexOf(m[3]!), lineMasked.indexOf(m[3]!) + m[3]!.length).trim())
  }
  const out: Record<string, Shape> = {}
  const initFrom = bodyMasked.match(/\binit\s*\(\s*from\s+\w+\s*:\s*(?:any\s+)?Decoder\s*\)[^{]*\{/)
  const ext = initFrom ? undefined : maskSwift(scope.file).match(new RegExp(`\\bextension\\s+${name}\\b[^{]*\\{[\\s\\S]*?\\binit\\s*\\(\\s*from\\s+\\w+\\s*:\\s*(?:any\\s+)?Decoder\\s*\\)`))
  if (initFrom || ext) {
    const src = initFrom ? body : scope.file
    const m = initFrom ? bodyMasked.match(/\binit\s*\(\s*from\s+\w+\s*:\s*(?:any\s+)?Decoder\s*\)[^{]*\{/)! : maskSwift(scope.file).match(/\binit\s*\(\s*from\s+\w+\s*:\s*(?:any\s+)?Decoder\s*\)[^{]*\{/)!
    const iOpen = m.index! + m[0].length - 1
    const iBody = src.slice(iOpen, closerOf(maskSwift(src), iOpen))
    for (const d of iBody.matchAll(/(try\?\s*)?\w+\.(decode|decodeIfPresent)\(\s*([^,]+?)\.self\s*,\s*forKey:\s*\.([A-Za-z_]\w*)\s*\)/g)) {
      const key = keys.get(d[4]!) ?? d[4]!
      const optional = !!d[1] || d[2] === "decodeIfPresent"
      const inner = typeShape(d[3]!, scope, depth, notes)
      out[optional || inner.optional ? `${key}?` : key] = inner.shape
    }
    if (!Object.keys(out).length) {
      notes.push(`${name} decodes itself without keyed fields (any value)`)
      return "any"
    }
    return out
  }
  for (const [prop, type] of props) {
    if (keys.size && !keys.has(prop)) continue
    const key = keys.get(prop) ?? prop
    const t = typeShape(type, scope, depth, notes)
    out[t.optional ? `${key}?` : key] = t.shape
  }
  return out
}

// ---------------------------------------------------------------- extraction

export interface Body {
  /** JSON body keys the client sends; a key ending in "?" is sent only sometimes. */
  readonly keys?: ReadonlyArray<string>
  /** An Encodable value or an expression the extractor does not expand. */
  readonly encodes?: string
}

export interface OldRequest {
  readonly method: string
  /** Path template; `{name}` marks a path parameter. */
  readonly path: string
  /** The literal query the client always sends (`?all=true`: from the path literal or literal `URLQueryItem`s). */
  readonly query?: string
  readonly params: ReadonlyArray<string>
  readonly headers: ReadonlyArray<string>
  readonly sources: ReadonlyArray<string>
  /** How the method was found (call argument, helper, function, review). */
  readonly via: string
  readonly body?: Body
  /** "read": replayed signed in, status and response shape checked. "shape-only": probed without credentials. */
  readonly mode: "read" | "shape-only"
  readonly reason?: string
  /** read: the shape a 2xx answer needs, and where it comes from. */
  readonly response?: Shape
  readonly responseFrom?: string
  /** read: what to send as the body (a read-like POST). */
  readonly replayBody?: unknown
  /** Path parameter -> "team" | "vm" | "publication" (from the signed-in account) or "=literal". */
  readonly fill?: Readonly<Record<string, string>>
  /** read: the client sends it without credentials (replayed the same way). */
  readonly anonymous?: boolean
}

export interface StackAuth {
  readonly api: string
  readonly signInPath: string
  readonly projectId: string
  readonly publishableClientKey: string
  readonly sources: ReadonlyArray<string>
}

export interface Spec {
  readonly schema: 2
  readonly tag: string
  readonly sha: string
  readonly generated_from: string
  readonly auth: StackAuth
  readonly requests: ReadonlyArray<OldRequest>
  readonly skipped: ReadonlyArray<{ readonly source: string; readonly reason: string }>
}

export interface Review {
  /** "<file>:<line>" of an "/api/" literal that is not a cmux.com request, with why. */
  readonly skip?: Record<string, string>
  /** "<file>:<line>" -> methods, when the source passes the method in a variable. */
  readonly methods?: Record<string, { readonly methods: ReadonlyArray<string>; readonly reason: string }>
  /**
   * "METHOD path" -> the shape a hand-written (dictionary) decoder needs, with its source line; or the
   * Decodable type the decoder uses (`decodable`, parsed like any other) when the source decodes it
   * away from the request (a stored URL, a parse helper).
   */
  readonly responses?: Record<string, { readonly shape?: Shape; readonly decodable?: string; readonly source: string }>
  /** "METHOD path" of a non-GET that is a read (no state change): replayed signed in with this body. */
  readonly reads?: Record<string, { readonly body: unknown; readonly reason: string }>
  /** "METHOD path" of a GET that is never replayed signed in, with why. */
  readonly shapeOnly?: Record<string, string>
  /** "METHOD path" of a read the client sends without credentials although no header code is visible near it. */
  readonly anonymous?: Record<string, string>
  /**
   * Path parameter -> where the replay takes a value from: "team", "vm" or "publication" (the agent
   * account's), or "=literal". Keys: "name", or "METHOD path#name" for one request.
   */
  readonly fill?: Record<string, string>
}

export const SPEC_DIR = join(import.meta.dirname, "cmux-old")

/** The fill source of path parameter `param` of request `key` ("METHOD path"). */
export const fillSource = (fill: Record<string, string> | undefined, key: string, param: string): string | undefined => fill?.[`${key}#${param}`] ?? fill?.[param]
export const ABSENT = "cmuxnp-dev-absent"

const SHIPPED = ["CLI", "Sources", "Packages", ":!**/*Tests*", ":!**/Tests/**", ":!**/*.md"]

/** Every shipped Swift file at `tag` (tests excluded), read with one `git cat-file --batch`. */
const swiftTree = (repo: string, tag: string): Map<string, string> => {
  const list = spawnSync("git", ["-C", repo, "ls-tree", "-r", tag, "--", "CLI", "Sources", "Packages"], { encoding: "utf8", maxBuffer: 64 << 20 })
  if (list.status !== 0) throw new Error(`git ls-tree ${tag}: ${list.stderr.trim()}`)
  const entries = list.stdout.split("\n").flatMap((l) => {
    const m = l.match(/^\d+ blob ([0-9a-f]+)\t(.+\.swift)$/)
    return m && !/Tests?\b|\/Tests\//.test(m[2]!) ? [[m[2]!, m[1]!] as const] : []
  })
  const batch = spawnSync("git", ["-C", repo, "cat-file", "--batch"], { input: entries.map(([, id]) => id).join("\n") + "\n", maxBuffer: 1 << 30 })
  const buf = batch.stdout as Buffer
  const out = new Map<string, string>()
  let at = 0
  for (const [path] of entries) {
    const nl = buf.indexOf(10, at)
    const size = Number(buf.subarray(at, nl).toString().split(" ")[2])
    out.set(path, buf.subarray(nl + 1, nl + 1 + size).toString("utf8"))
    at = nl + 1 + size + 1
  }
  return out
}

interface Resolution {
  readonly method: string
  readonly via: string
  readonly at: number
}

/** The requests one "/api/" literal at `pos` makes: [] when the source does not say. */
const resolveMethods = (src: string, masked: string, pos: number, literalEnd: number, seen = 0): Array<Resolution> => {
  // A binding (`let path = "/api/..."`, `static let requestPath = ...`): the requests are made where it is used.
  const lineStart = src.lastIndexOf("\n", pos) + 1
  const binding = masked.slice(lineStart, pos).match(/(?:let|var)\s+([A-Za-z_]\w*)(?:\s*:\s*[\w?]+)?\s*=\s*$/)
  if (binding && seen < 2 && masked.slice(literalEnd).match(/^\s*(\n|$)/)) {
    const out: Array<Resolution> = []
    for (const use of masked.matchAll(new RegExp(`\\b${binding[1]}\\b`, "g"))) {
      if (use.index! >= lineStart && use.index! < literalEnd) continue
      const after = masked.slice(use.index! + binding[1]!.length).match(/^\s*(\+?=)/)
      if (after) continue // reassignment
      out.push(...resolveMethods(src, masked, use.index!, use.index! + binding[1]!.length, seen + 1))
    }
    return out
  }
  const call = enclosingCall(src, masked, pos)
  if (call && !URL_BUILDERS.has(call.callee)) {
    const literal = call.args.find((a) => !a.label && methodLiteral(a.value)) ?? call.args.find((a) => a.label === "method" && methodLiteral(a.value))
    if (literal) return [{ method: methodLiteral(literal.value)!, via: `argument of ${call.callee}(...)`, at: pos }]
    const defs = funcDefs(src, masked, call.callee)
    const methods = new Set(defs.flatMap((d) => [...assignedMethods(d.body)]))
    if (defs.length && methods.size && !defs.some((d) => setsMethodFromVariable(d.body))) return [...methods].map((method) => ({ method, via: `${call.callee}(...) sets httpMethod`, at: pos }))
    const forwarded = new Set(defs.flatMap((d) => [...forwardedMethods(d.body)]))
    if (defs.length && !methods.size && forwarded.size === 1) return [{ method: [...forwarded][0]!, via: `${call.callee}(...) sends ${[...forwarded][0]}`, at: pos }]
    if (defs.length) return []
  }
  const func = enclosingFunc(src, masked, pos)
  if (!func) return []
  const methods = assignedMethods(func.body)
  if (methods.size && !setsMethodFromVariable(func.body)) return [...methods].map((method) => ({ method, via: `${func.name}() sets httpMethod`, at: pos }))
  if (methods.size === 0 && /\bURLRequest\s*\(/.test(func.body) && !setsMethodFromVariable(func.body)) return [{ method: "GET", via: `${func.name}() builds a URLRequest without httpMethod (GET)`, at: pos }]
  // A URL helper (`func pushURL() -> URL?`): the requests are made where it is called.
  if (methods.size === 0 && !/\bURLRequest\s*\(/.test(func.body) && seen < 2 && func.name !== "init") {
    const out: Array<Resolution> = []
    for (const use of masked.matchAll(new RegExp(`\\b${func.name}\\(`, "g"))) {
      if (use.index! >= func.start - 400 && use.index! <= func.end) continue
      out.push(...resolveMethods(src, masked, use.index!, use.index! + func.name.length, seen + 1).map((r) => ({ ...r, via: `${r.via} (via ${func.name}())` })))
    }
    return out
  }
  return []
}

const bodyOf = (src: string, masked: string, at: number): Body | undefined => {
  const call = enclosingCall(src, masked, at)
  const arg = call?.args.find((a) => a.label === "jsonBody" || a.label === "body")
  const func = enclosingFunc(src, masked, at)
  const literalKeys = (text: string) => {
    const m = maskSwift(text)
    const keys: Array<string> = []
    let depth = 0
    for (let i = 0; i < text.length; i++) {
      const c = m[i]!
      if (OPEN[c]) depth++
      else if (CLOSE[c]) depth--
      else if (c === '"' && depth === 1) {
        const k = text.slice(i).match(/^"([^"\\]+)"\s*:/)
        if (k) keys.push(k[1]!)
        const end = text.indexOf('"', i + 1)
        i = end < 0 ? i : end
      }
    }
    return keys
  }
  const fromVariable = (name: string): Body | undefined => {
    if (!func) return undefined
    const fm = maskSwift(func.body)
    const decl = fm.match(new RegExp(`(?:let|var)\\s+${name}\\b[^=\\n]*=\\s*\\[`))
    if (!decl || decl.index === undefined) return undefined
    const open = decl.index + decl[0].length - 1
    const keys = literalKeys(func.body.slice(open, closerOf(fm, open) + 1))
    const later = [...func.body.matchAll(new RegExp(`\\b${name}\\["([^"]+)"\\]\\s*=`, "g"))].map((m) => `${m[1]}?`)
    return { keys: [...new Set([...keys, ...later.filter((k) => !keys.includes(k.slice(0, -1)))])] }
  }
  if (arg) {
    if (arg.value === "nil") return undefined
    if (arg.value.startsWith("[")) return { keys: arg.value === "[:]" ? [] : literalKeys(arg.value) }
    const ident = arg.value.match(/^([A-Za-z_]\w*)$/)?.[1]
    return (ident ? fromVariable(ident) : undefined) ?? { encodes: arg.value.replace(/\s+/g, " ").slice(0, 120) }
  }
  if (!func) return undefined
  const json = func.body.match(/JSONSerialization\.data\(\s*withJSONObject:\s*([A-Za-z_]\w*|\[)/)
  if (json) return json[1] === "[" ? { encodes: "dictionary literal" } : (fromVariable(json[1]!) ?? { encodes: json[1]! })
  const enc = func.body.match(/\.encode\(\s*([^)]+)\)/)
  if (enc && /httpBody/.test(func.body)) return { encodes: enc[1]!.trim() }
  return undefined
}

interface ExtractedRequest {
  method: string
  path: string
  query?: string
  params: Array<string>
  headers: Set<string>
  sources: Set<string>
  via: Set<string>
  body?: Body
  decodes?: { type: string; array: boolean; source: string; scope: SourceScope }
}

/** Requests the tag's shipped Swift builds, from the source alone; throws when a literal is neither resolved nor reviewed. */
export const extractRequests = (repo: string, tag: string, review: Review = {}): { requests: Array<ExtractedRequest>; skipped: Array<{ source: string; reason: string }> } => {
  const grep = spawnSync("git", ["-C", repo, "grep", "-n", "-E", '"/api/', tag, "--", ...SHIPPED], { encoding: "utf8", maxBuffer: 64 << 20 })
  if (grep.status === 128) throw new Error(`git grep at ${tag}: ${grep.stderr.trim()}`)
  const tree = swiftTree(repo, tag)
  const files = new Map<string, { src: string; masked: string; offsets: Array<number> }>()
  const load = (path: string) => {
    if (!files.has(path)) {
      const src = tree.get(path) ?? execFileSync("git", ["-C", repo, "show", `${tag}:${path}`], { encoding: "utf8", maxBuffer: 64 << 20 })
      const offsets = [0]
      for (let i = 0; i < src.length; i++) if (src[i] === "\n") offsets.push(i + 1)
      files.set(path, { src, masked: maskSwift(src), offsets })
    }
    return files.get(path)!
  }
  const shipped = [...tree.keys()]
  const others = (near: string) => () => {
    const pkg = near.includes("/Sources/") ? near.slice(0, near.indexOf("/Sources/")) : near.split("/")[0]!
    const ordered = [...shipped.filter((f) => f.startsWith(pkg) && f !== near), ...shipped.filter((f) => !f.startsWith(pkg))]
    return ordered.map((f) => [f, tree.get(f)!] as [string, string])
  }
  const found = new Map<string, ExtractedRequest>()
  const skipped: Array<{ source: string; reason: string }> = []
  const unresolved: Array<string> = []
  const usedReview = new Set<string>()
  for (const hit of grep.stdout.split("\n").filter(Boolean)) {
    const m = hit.match(/^[^:]+:([^:]+):(\d+):(.*)$/)
    if (!m || !m[1]!.endsWith(".swift")) continue
    const [, path, num] = m
    const site = `${path}:${num}`
    const file = load(path!)
    const lineStart = file.offsets[Number(num) - 1]!
    const lineEnd = file.src.indexOf("\n", lineStart)
    const line = file.src.slice(lineStart, lineEnd < 0 ? undefined : lineEnd)
    if (review.skip?.[site]) {
      usedReview.add(`skip ${site}`)
      skipped.push({ source: site, reason: review.skip[site]! })
      continue
    }
    for (const lit of line.matchAll(/"(\/api\/(?:[^"\\]|\\\((?:[^()]|\([^()]*\))*\)|\\.)*)"/g)) {
      const pos = lineStart + lit.index!
      if (file.masked[pos] !== '"' || file.masked[pos + 1] !== " ") continue // in a comment, or inside another string
      const { path: template, params } = pathTemplate(lit[1]!)
      const reviewed = review.methods?.[site]
      if (reviewed) usedReview.add(`methods ${site}`)
      const resolutions = reviewed ? reviewed.methods.map((method) => ({ method, via: `review: ${reviewed.reason}`, at: pos })) : resolveMethods(file.src, file.masked, pos, pos + lit[0].length)
      if (!resolutions.length) {
        unresolved.push(`${site}: ${line.trim().slice(0, 140)}`)
        continue
      }
      for (const r of resolutions) {
        // Two clients may name one route's parameter differently ({id}, {encodedID}): one request.
        const key = `${r.method} ${template.replace(/\{[^}]+\}/g, "{}")}`
        const entry = found.get(key) ?? { method: r.method, path: template, params, headers: new Set<string>(), sources: new Set<string>(), via: new Set<string>() }
        entry.sources.add(site)
        entry.via.add(r.via)
        const func = enclosingFunc(file.src, file.masked, r.at)
        entry.query ??= literalQuery(lit[1]!, func?.body)
        const call = enclosingCall(file.src, file.masked, r.at)
        for (const h of setHeaders(func?.body ?? "")) entry.headers.add(h)
        if (call && !URL_BUILDERS.has(call.callee)) {
          let defs = funcDefs(file.src, file.masked, call.callee)
          // A helper defined in another file of the package (extensions of one client type).
          if (!defs.length) {
            // The nearest file that defines it: same directory first, then the package.
            const dir = path!.slice(0, path!.lastIndexOf("/") + 1)
            const candidates = others(path!)().filter(([f]) => f.startsWith(dir.split("/Sources/")[0]!))
            const owner = [...candidates.filter(([f]) => f.startsWith(dir)), ...candidates].find(([, text]) => text.includes(`func ${call.callee}(`))
            if (owner) defs = funcDefs(owner[1], maskSwift(owner[1]), call.callee)
          }
          for (const d of defs) for (const h of setHeaders(d.body)) entry.headers.add(h)
        }
        if (r.method !== "GET" || entry.method !== "GET") entry.body ??= bodyOf(file.src, file.masked, r.at)
        if (!entry.decodes && func) {
          const after = func.body.slice(Math.max(0, r.at - func.start))
          const d = after.match(/\.decode\(\s*(\[)?\s*([A-Za-z_][\w.]*)\s*\]?\.self/)
          if (d) entry.decodes = { type: d[2]!.split(".").at(-1)!, array: !!d[1], source: site, scope: { func: func.body, file: file.src, others: others(path!) } }
        }
        found.set(key, entry)
      }
    }
  }
  const stale = [...Object.keys(review.skip ?? {}).map((s) => `skip ${s}`), ...Object.keys(review.methods ?? {}).map((s) => `methods ${s}`)].filter((k) => !usedReview.has(k))
  const problems = [...unresolved.map((u) => `unresolved "/api/" literal (add a skip or methods entry to the review file): ${u}`), ...stale.map((s) => `review entry ${s} matches no "/api/" literal at ${tag}`)]
  if (problems.length) throw new Error(problems.join("\n"))
  const requests = [...found.values()].sort((a, b) => `${a.path} ${a.method}`.localeCompare(`${b.path} ${b.method}`))
  return { requests, skipped: skipped.sort((a, b) => a.source.localeCompare(b.source)) }
}

/** How the tag signs in to Stack for the staging (development) project, read from its source. */
export const extractStackAuth = (repo: string, tag: string): StackAuth => {
  const show = (path: string) => execFileSync("git", ["-C", repo, "show", `${tag}:${path}`], { encoding: "utf8", maxBuffer: 64 << 20 })
  const configPath = "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthConfig.swift"
  const clientPath = "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Client/StackAuthClient.swift"
  const sdkApp = "vendor/stack-auth-swift-sdk-prerelease/Sources/StackAuth/StackClientApp.swift"
  const sdkApi = "vendor/stack-auth-swift-sdk-prerelease/Sources/StackAuth/APIClient.swift"
  const config = show(configPath)
  const projectId = config.match(/developmentProjectId:\s*"([^"]+)"/)?.[1]
  const publishableClientKey = config.match(/developmentPublishableClientKey:\s*"([^"]+)"/)?.[1]
  const api = show(clientPath).match(/baseURL:\s*String\s*=\s*"([^"]+)"/)?.[1]
  const signIn = show(sdkApp).match(/func signInWithCredential[\s\S]*?path:\s*"([^"]+)"/)?.[1]
  const prefix = show(sdkApi).match(/"\\\(baseUrl\)(\/[^\\"]+)\\\(path\)"/)?.[1]
  if (!projectId || !publishableClientKey || !api || !signIn || !prefix) throw new Error(`could not read the Stack sign-in from ${tag} (${configPath}, ${clientPath}, ${sdkApp}, ${sdkApi})`)
  return { api, signInPath: `${prefix}${signIn}`, projectId, publishableClientKey, sources: [configPath, clientPath, sdkApp, sdkApi] }
}

export const readReview = (tag: string, dir = SPEC_DIR): Review => {
  const file = join(dir, `${tag}.review.json`)
  return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Review) : {}
}

export const generate = (repo: string, tag: string, review: Review = readReview(tag)): Spec => {
  const sha = execFileSync("git", ["-C", repo, "rev-list", "-n", "1", tag], { encoding: "utf8" }).trim()
  const { requests: extracted, skipped } = extractRequests(repo, tag, review)
  const problems: Array<string> = []
  const keys = new Set(extracted.map((r) => `${r.method} ${r.path}`))
  for (const section of ["responses", "reads", "shapeOnly", "anonymous"] as const) for (const k of Object.keys(review[section] ?? {})) if (!keys.has(k)) problems.push(`review ${section} entry "${k}" is not a request of ${tag}`)
  const requests: Array<OldRequest> = []
  let tree: Map<string, string> | undefined
  for (const r of extracted) {
    const key = `${r.method} ${r.path}`
    const read = r.method === "GET" ? !review.shapeOnly?.[key] : !!review.reads?.[key]
    const fill = Object.fromEntries(r.params.flatMap((p) => (fillSource(review.fill, key, p) ? [[p, fillSource(review.fill, key, p)!]] : [])))
    const base = { method: r.method, path: r.path, ...(r.query ? { query: r.query } : {}), params: r.params, headers: [...r.headers].sort(), sources: [...r.sources].sort(), via: [...r.via].sort().join("; "), ...(r.body ? { body: r.body } : {}), ...(Object.keys(fill).length ? { fill } : {}) }
    if (!read) {
      requests.push({ ...base, mode: "shape-only", reason: review.shapeOnly?.[key] ?? "changes state: never replayed signed in; probed without credentials (route present, auth layer intact)" })
      continue
    }
    for (const p of r.params) if (!fill[p]) problems.push(`${key}: no fill source for path parameter {${p}} (review fill)`)
    const reviewed = review.responses?.[key]
    let response: Shape | undefined
    let responseFrom: string | undefined
    if (reviewed?.decodable) {
      const at0 = reviewed.source.match(/^(\S+?):(\d+)/)
      if (!at0) throw new Error(`${key}: review source must start with <file>:<line>`)
      const file = at0[1]!
      const text = execFileSync("git", ["-C", repo, "show", `${tag}:${file}`], { encoding: "utf8", maxBuffer: 64 << 20 })
      const line = Number(at0[2])
      const at = text.split("\n").slice(0, Math.max(0, line - 1)).join("\n").length
      const func = enclosingFunc(text, maskSwift(text), at)
      const notes: Array<string> = []
      tree ??= swiftTree(repo, tag)
      const pkg = file.includes("/Sources/") ? file.slice(0, file.indexOf("/Sources/")) : file.split("/")[0]!
      const near = [...tree.entries()].sort(([a], [b]) => Number(!a.startsWith(pkg)) - Number(!b.startsWith(pkg)))
      const shape = structShape(reviewed.decodable, { ...(func ? { func: func.body } : {}), file: text, others: () => near }, 0, notes)
      if (shape === undefined) problems.push(`${key}: review names Decodable ${reviewed.decodable}, which ${file} does not declare`)
      else {
        response = shape
        responseFrom = `Decodable ${reviewed.decodable} (review: ${reviewed.source})${notes.length ? `; ${[...new Set(notes)].join("; ")}` : ""}`
      }
    } else if (reviewed?.shape !== undefined) {
      response = reviewed.shape
      responseFrom = `review of the decoder at ${reviewed.source}`
    } else if (r.decodes) {
      const notes: Array<string> = []
      const shape = structShape(r.decodes.type, r.decodes.scope, 0, notes)
      if (shape === undefined) problems.push(`${key}: decodes ${r.decodes.type}, which the shipped source does not declare`)
      else {
        response = r.decodes.array ? [shape] : shape
        responseFrom = `Decodable ${r.decodes.array ? `[${r.decodes.type}]` : r.decodes.type} (${r.decodes.source})${notes.length ? `; ${[...new Set(notes)].join("; ")}` : ""}`
      }
    } else problems.push(`${key}: no Decodable type near ${[...r.sources].join(", ")}; add a review responses entry with the shape its decoder reads`)
    const anonymous = !!review.anonymous?.[key] || (r.headers.size > 0 && ![...r.headers].some((h) => h.toLowerCase() === "authorization"))
    requests.push({ ...base, mode: "read", ...(anonymous ? { anonymous: true } : {}), ...(review.reads?.[key] ? { reason: review.reads[key]!.reason, replayBody: review.reads[key]!.body } : {}), ...(response !== undefined ? { response, responseFrom: responseFrom! } : {}) })
  }
  if (problems.length) throw new Error(problems.join("\n"))
  return { schema: 2, tag, sha, generated_from: `git show ${tag} (shipped Swift: ${SHIPPED.join(" ")}) + cmux-old/${tag}.review.json`, auth: extractStackAuth(repo, tag), requests, skipped }
}

// ---------------------------------------------------------------- credentials and sign-in

export interface Credentials {
  readonly email: string
  readonly password: string
}

const AGENT = ["CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD"] as const
const PERSONAL_EMAIL = "CMUX_DOGFOOD_STACK_EMAIL"

const parseDotenv = (text: string): Map<string, string> => {
  const out = new Map<string, string>()
  for (const raw of text.split("\n")) {
    const m = raw.match(/^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)
    if (!m) continue
    let v = m[2]!
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1)
    out.set(m[1]!, v)
  }
  return out
}

/**
 * The AGENT test profile (CMUX_UITEST_STACK_*), from the environment first, else the dotenv text.
 * Only those names are kept; it refuses when the agent email equals the personal (dogfood) one.
 * Error messages name variables, never values.
 */
export const agentCredentials = (env: Record<string, string | undefined>, dotenv?: string): Credentials => {
  const file = dotenv === undefined ? new Map<string, string>() : parseDotenv(dotenv)
  const pick = (name: string) => env[name] || file.get(name) || ""
  const email = pick(AGENT[0])
  const password = pick(AGENT[1])
  if (!email || !password) throw new Error(`the agent profile needs ${AGENT.join(" and ")} (environment or credentials file)`)
  const personal = env[PERSONAL_EMAIL] || file.get(PERSONAL_EMAIL)
  if (personal && personal.trim().toLowerCase() === email.trim().toLowerCase()) throw new Error(`${AGENT[0]} names the personal profile (${PERSONAL_EMAIL}); the replay signs in as the agent profile only`)
  return { email, password }
}

export interface Session {
  readonly accessToken: string
  readonly refreshToken: string
  readonly userId?: string
  readonly teamId?: string
}

type Fetch = (input: string | URL, init?: RequestInit) => Promise<Response>

const stackHeaders = (auth: StackAuth) => ({
  "x-stack-project-id": auth.projectId,
  "x-stack-publishable-client-key": auth.publishableClientKey,
  "x-stack-access-type": "client",
  "x-stack-client-version": "swift@1.0.0",
  "user-agent": "cmux-release-rails/cmux-old-replay",
})

/** Password sign-in exactly as the tag's Stack SDK does it, then the user's selected team. */
export const signIn = async (auth: StackAuth, creds: Credentials, doFetch: Fetch = fetch): Promise<Session> => {
  const res = await doFetch(`${auth.api}${auth.signInPath}`, {
    method: "POST",
    headers: { ...stackHeaders(auth), "content-type": "application/json" },
    body: JSON.stringify({ email: creds.email, password: creds.password }),
    signal: AbortSignal.timeout(20_000),
  })
  const body = (await res.json().catch(() => ({}))) as Record<string, unknown>
  if (!res.ok || typeof body.access_token !== "string" || typeof body.refresh_token !== "string") throw new Error(`Stack sign-in for the agent profile answered ${res.status}${typeof body.code === "string" ? ` ${body.code}` : ""}`)
  const session: Session = { accessToken: body.access_token, refreshToken: body.refresh_token, ...(typeof body.user_id === "string" ? { userId: body.user_id } : {}) }
  const me = await doFetch(`${auth.api}${auth.signInPath.replace(/\/auth\/password\/sign-in$/, "")}/users/me`, { headers: { ...stackHeaders(auth), "x-stack-access-token": session.accessToken, "x-stack-refresh-token": session.refreshToken }, signal: AbortSignal.timeout(20_000) })
  const user = (await me.json().catch(() => ({}))) as Record<string, unknown>
  const team = typeof user.selected_team_id === "string" ? user.selected_team_id : typeof (user.selected_team as Record<string, unknown> | undefined)?.id === "string" ? ((user.selected_team as Record<string, unknown>).id as string) : undefined
  return { ...session, ...(team ? { teamId: team } : {}), ...(typeof user.id === "string" ? { userId: user.id } : {}) }
}

/** Ends the replay's Stack session (best effort): nothing it signed in stays alive. */
export const signOut = async (auth: StackAuth, session: Session, doFetch: Fetch = fetch): Promise<boolean> => {
  const res = await doFetch(`${auth.api}${auth.signInPath.replace(/\/password\/sign-in$/, "")}/sessions/current`, {
    method: "DELETE",
    headers: { ...stackHeaders(auth), "x-stack-access-token": session.accessToken, "x-stack-refresh-token": session.refreshToken, "content-type": "application/json" },
    body: "{}",
    signal: AbortSignal.timeout(20_000),
  }).catch(() => undefined)
  return !!res?.ok
}

// ---------------------------------------------------------------- web revisions

export interface Revision {
  readonly host: string
  readonly sha?: string
  readonly deployment?: string
  readonly error?: string
}

export interface Revisions {
  readonly staging: Revision
  readonly production: Revision
  /** same | newer | older | diverged | unknown: staging relative to production. */
  readonly relation: "same" | "newer" | "older" | "diverged" | "unknown"
  readonly source: string
}

export const STAGING_HOST = "cmux-staging.vercel.app"
export const PRODUCTION_HOST = "cmux.com"
const VERCEL_TEAM = "team_KndpHsJ15gO2OoAP2SO0thYn"

/** The git commit a Vercel deployment serves, through the logged-in Vercel CLI (read-only GET). */
export const vercelRevision = (host: string): Revision => {
  const run = spawnSync("vercel", ["api", `/v13/deployments/${host}?teamId=${VERCEL_TEAM}`, "--raw"], { encoding: "utf8", timeout: 60_000 })
  if (run.status !== 0) return { host, error: `vercel api exited ${run.status ?? run.signal}: ${(run.stderr || "").trim().split("\n").at(-1)?.slice(0, 160) ?? ""}` }
  try {
    const d = JSON.parse(run.stdout) as { url?: string; gitSource?: { sha?: string }; meta?: { githubCommitSha?: string } }
    const sha = d.gitSource?.sha ?? d.meta?.githubCommitSha
    return sha ? { host, sha, ...(d.url ? { deployment: d.url } : {}) } : { host, error: "the deployment records no git commit" }
  } catch {
    return { host, error: "vercel api answered no JSON" }
  }
}

/** Staging relative to production: same commit, a descendant (newer), an ancestor (older), or neither. */
export const relate = (staging: string | undefined, production: string | undefined, isAncestor: (a: string, b: string) => boolean | undefined): Revisions["relation"] => {
  if (!staging || !production) return "unknown"
  if (staging === production) return "same"
  const prodInStaging = isAncestor(production, staging)
  const stagingInProd = isAncestor(staging, production)
  if (prodInStaging === undefined || stagingInProd === undefined) return "unknown"
  return prodInStaging ? "newer" : stagingInProd ? "older" : "diverged"
}

export const gitIsAncestor = (root: string) => (a: string, b: string): boolean | undefined => {
  for (const sha of [a, b]) if (spawnSync("git", ["-C", root, "cat-file", "-e", `${sha}^{commit}`]).status !== 0) spawnSync("git", ["-C", root, "fetch", "--quiet", "--no-tags", "origin", sha])
  const run = spawnSync("git", ["-C", root, "merge-base", "--is-ancestor", a, b])
  return run.status === 0 ? true : run.status === 1 ? false : undefined
}

export const webRevisions = (root = REPO_ROOT, lookup: (host: string) => Revision = vercelRevision, isAncestor = gitIsAncestor(root)): Revisions => {
  const staging = lookup(STAGING_HOST)
  const production = lookup(PRODUCTION_HOST)
  return { staging, production, relation: relate(staging.sha, production.sha, isAncestor), source: "vercel api /v13/deployments/<host> (gitSource.sha)" }
}

// ---------------------------------------------------------------- replay

export interface Fill {
  readonly team?: string
  readonly vm?: string
  readonly publication?: string
}

export interface ReplayResult {
  readonly ok: boolean
  readonly authenticated: boolean
  readonly lines: Array<string>
  readonly failures: Array<string>
  readonly warnings: Array<string>
  readonly counts: Record<string, number>
  readonly shapeOnly: Array<string>
}

export interface Gap {
  readonly method: string
  readonly path: string
  readonly status: number
  readonly reason: string
}

export const readGaps = (file = join(SPEC_DIR, "staging-gaps.json")): Array<Gap> => (existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as { gaps: Array<Gap> }).gaps : [])

const statusOk = (code: number) => code >= 200 && code < 300
/** The client sends Stack credentials with this read (generate decides; `anonymous` marks the ones it sends without). */
const isPrivate = (r: OldRequest) => !r.anonymous
const isJson = (res: Response) => (res.headers.get("content-type") ?? "").includes("json")

/** Path parameters from the signed-in account: the selected team, its first machine and publication. */
export const discoverFill = async (origin: string, session: Session, doFetch: Fetch = fetch): Promise<Fill> => {
  const get = async (path: string) => {
    const res = await doFetch(new URL(path, origin), { headers: authHeaders(session), redirect: "manual", signal: AbortSignal.timeout(30_000) }).catch(() => undefined)
    return res && statusOk(res.status) ? ((await res.json().catch(() => undefined)) as Record<string, unknown> | undefined) : undefined
  }
  const firstId = (list: unknown) => (Array.isArray(list) ? list.map((x) => (x as Record<string, unknown>)?.id).find((x): x is string => typeof x === "string") : undefined)
  const vms = await get("/api/vm")
  const pubs = await get("/api/vm/publications")
  const vm = firstId(vms?.vms)
  const publication = firstId(pubs?.publications)
  return { ...(session.teamId ? { team: session.teamId } : {}), ...(vm ? { vm } : {}), ...(publication ? { publication } : {}) }
}

/** The headers every signed-in v0.65.0 client sets (the team one whenever a team is resolved). */
const authHeaders = (session: Session): Record<string, string> => ({
  accept: "application/json",
  authorization: `Bearer ${session.accessToken}`,
  "x-stack-refresh-token": session.refreshToken,
  ...(session.teamId ? { "x-cmux-team-id": session.teamId } : {}),
  "user-agent": "cmux-release-rails/cmux-old-replay",
})

export interface ReplayOptions {
  readonly session?: Session
  readonly fill?: Fill
  readonly gaps?: ReadonlyArray<Gap>
  readonly fetch?: Fetch
}

/**
 * Replays `spec` against `origin`. Signed in (a session): a read must answer 2xx with the shape its
 * decoder needs, or, when a path parameter has no value on this account, a JSON 4xx (the route
 * answered for an absent id). Every shape-only request, and every request without a session, is
 * probed without credentials and must not answer 404, 405 or 5xx; a public read that answers 2xx
 * must still have its shape.
 */
export const replay = async (spec: Spec, origin: string, options: ReplayOptions = {}): Promise<ReplayResult> => {
  const doFetch = options.fetch ?? fetch
  const lines: Array<string> = []
  const failures: Array<string> = []
  const warnings: Array<string> = []
  const counts: Record<string, number> = { "read-2xx": 0, "read-absent-id": 0, "public-read": 0, "unauthenticated-read": 0, "shape-only": 0, gap: 0, fail: 0 }
  const shapeOnly: Array<string> = []
  for (const r of spec.requests) {
    const publicRead = r.mode === "read" && !isPrivate(r)
    const signedIn = !!options.session && r.mode === "read" && !publicRead
    let path = r.path
    let absent = false
    for (const p of r.params) {
      const source = r.fill?.[p]
      const value = source?.startsWith("=") ? source.slice(1) : signedIn && source ? options.fill?.[source as keyof Fill] : undefined
      if (!value) absent = true
      path = path.replace(`{${p}}`, encodeURIComponent(value ?? ABSENT))
    }
    const sendBody = r.method !== "GET" && r.method !== "DELETE"
    const body = signedIn && r.replayBody !== undefined ? JSON.stringify(r.replayBody) : "{}"
    let res: Response
    let text: string
    try {
      res = await doFetch(new URL(r.query ? `${path}?${r.query}` : path, origin), {
        method: r.method,
        redirect: "manual",
        signal: AbortSignal.timeout(30_000),
        headers: { ...(signedIn ? authHeaders(options.session!) : { "user-agent": "cmux-release-rails/cmux-old-replay" }), ...(sendBody ? { "content-type": "application/json" } : {}) },
        ...(sendBody ? { body } : {}),
      })
      text = await res.text()
    } catch (e) {
      failures.push(`${r.method} ${r.path}: ${(e as Error).message}`)
      counts.fail!++
      continue
    }
    let problem: string | undefined
    let kind: string
    const parsed = (() => {
      try {
        return isJson(res) ? (JSON.parse(text) as unknown) : undefined
      } catch {
        return undefined
      }
    })()
    if ((signedIn || publicRead) && !absent) {
      kind = publicRead ? "public-read" : "read-2xx"
      if (!statusOk(res.status)) problem = `answered ${res.status}${signedIn ? " signed in" : " (the client sends no credentials)"}; ${spec.tag} needs 2xx`
      else if (r.response !== undefined) {
        if (parsed === undefined) problem = `answered ${res.status} without JSON; ${spec.tag} decodes JSON`
        else {
          const p = shapeProblems(r.response, parsed)
          if (p.length) problem = `response shape: ${p.slice(0, 6).join("; ")}${p.length > 6 ? ` (+${p.length - 6} more)` : ""}`
        }
      }
    } else if (signedIn) {
      kind = "read-absent-id"
      if (!(res.status >= 400 && res.status < 500 && res.status !== 405 && parsed !== undefined) && !statusOk(res.status)) problem = `answered ${res.status}${parsed === undefined ? " without JSON" : ""} for an absent id; the route must answer a JSON 4xx`
    } else {
      kind = r.mode === "read" ? "unauthenticated-read" : "shape-only"
      if (r.mode === "shape-only") shapeOnly.push(`${r.method} ${r.path}`)
      if (res.status === 404 || res.status === 405 || res.status >= 500) problem = `answered ${res.status}: the route ${spec.tag} calls is gone or broken`
      else if (statusOk(res.status) && r.mode === "read" && r.response !== undefined && parsed !== undefined) {
        const p = shapeProblems(r.response, parsed)
        if (p.length) problem = `response shape: ${p.slice(0, 6).join("; ")}`
      }
    }
    const gap = problem ? options.gaps?.find((g) => g.method === r.method && g.path === r.path && g.status === res.status) : undefined
    if (gap) {
      warnings.push(`known staging gap ${r.method} ${r.path} ${res.status}: ${gap.reason}`)
      lines.push(`GAP  ${r.method} ${r.path}: ${res.status} (${gap.reason})`)
      counts.gap!++
      continue
    }
    // The answer's first bytes say why (an error code); never a token: requests carry none in their bodies.
    const said = problem && !statusOk(res.status) ? ` [${text.slice(0, 120).replace(/\s+/g, " ")}]` : ""
    lines.push(`${problem ? "FAIL" : "PASS"} ${kind.padEnd(20)} ${r.method} ${r.path}: ${res.status}${problem ? ` (${problem})${said}` : ""}`)
    if (problem) {
      failures.push(`${r.method} ${r.path}: ${problem}${said}`)
      counts.fail!++
    } else counts[kind] = (counts[kind] ?? 0) + 1
  }
  return { ok: failures.length === 0, authenticated: !!options.session, lines, failures, warnings, counts, shapeOnly }
}

/** The staging origin must serve the Stack project the tag signs in to (else the session means nothing there). */
export const stagingProjectProblem = async (origin: string, auth: StackAuth, doFetch: Fetch = fetch): Promise<string | undefined> => {
  const res = await doFetch(new URL("/handler/sign-in", origin), { signal: AbortSignal.timeout(20_000) }).catch(() => undefined)
  if (!res) return `could not read ${origin}/handler/sign-in to confirm its Stack project`
  const html = await res.text()
  return html.includes(auth.projectId) ? undefined : `${origin} does not serve the Stack project ${auth.projectId} the spec signs in to`
}

export interface FullReplay extends ReplayResult {
  readonly revisions?: Revisions
}

/** Sign in as the agent, discover parameters, replay, sign out. Without credentials: unauthenticated only. */
export const authenticatedReplay = async (spec: Spec, origin: string, creds: Credentials | undefined, options: { gaps?: ReadonlyArray<Gap>; fetch?: Fetch; revisions?: Revisions } = {}): Promise<FullReplay> => {
  if (!creds) {
    const r = await replay(spec, origin, { ...(options.gaps ? { gaps: options.gaps } : {}), ...(options.fetch ? { fetch: options.fetch } : {}) })
    return { ...r, ...(options.revisions ? { revisions: options.revisions } : {}) }
  }
  const doFetch = options.fetch ?? fetch
  const project = await stagingProjectProblem(origin, spec.auth, doFetch)
  if (project) return { ok: false, authenticated: false, lines: [], failures: [project], warnings: [], counts: {}, shapeOnly: [] }
  const session = await signIn(spec.auth, creds, doFetch)
  try {
    const fill = await discoverFill(origin, session, doFetch)
    const r = await replay(spec, origin, { session, fill, ...(options.gaps ? { gaps: options.gaps } : {}), fetch: doFetch })
    const warnings = [...r.warnings, ...(!fill.vm ? ["the agent account has no machine: machine reads were checked as absent-id (JSON 4xx), not for shape"] : []), ...(!fill.publication ? ["the agent account has no publication: publication reads were checked as absent-id"] : [])]
    return { ...r, warnings, ...(options.revisions ? { revisions: options.revisions } : {}) }
  } finally {
    if (!(await signOut(spec.auth, session, doFetch))) console.error("warning: could not end the replay's Stack session (it expires on its own)")
  }
}

/** The newest spec on disk (by tag, semver order). */
export const newestSpec = (dir = SPEC_DIR): Spec | undefined => {
  if (!existsSync(dir)) return undefined
  const tags = readdirSync(dir)
    .filter((f) => /^v\d+\.\d+\.\d+\.json$/.test(f))
    .map((f) => f.slice(0, -5))
    .sort((a, b) => a.slice(1).split(".").map(Number).reduce((acc, n, i) => acc || n - Number(b.slice(1).split(".")[i]), 0))
  const tag = tags.at(-1)
  return tag ? (JSON.parse(readFileSync(join(dir, `${tag}.json`), "utf8")) as Spec) : undefined
}

export const DEFAULT_CREDENTIALS = join(homedir(), ".secrets", "cmuxterm-dev.env")
export const STAGING_ORIGIN = `https://${STAGING_HOST}`

/**
 * Credentials for the replay: CMUX_UITEST_STACK_* from the environment, else the dotenv file
 * (`file`, else CMUX_RELEASE_AGENT_CREDENTIALS, else ~/.secrets/cmuxterm-dev.env; "-" reads stdin).
 * The personal-profile refusal compares against CMUX_DOGFOOD_STACK_EMAIL from the environment, that
 * file and `personalFile` (default ~/.secrets/cmuxterm-dev.env), so an agent file that names no
 * personal profile is still checked. Undefined when no file exists.
 */
export const loadCredentials = (env: Record<string, string | undefined>, file: string | undefined, personalFile = DEFAULT_CREDENTIALS): Credentials | undefined => {
  const personal = env[PERSONAL_EMAIL] || (existsSync(personalFile) ? parseDotenv(readFileSync(personalFile, "utf8")).get(PERSONAL_EMAIL) : undefined)
  const guarded = personal ? { ...env, [PERSONAL_EMAIL]: personal } : env
  if (env[AGENT[0]] && env[AGENT[1]]) return agentCredentials(guarded)
  const path = file ?? (env.CMUX_RELEASE_AGENT_CREDENTIALS || DEFAULT_CREDENTIALS)
  const text = path === "-" ? readFileSync(0, "utf8") : existsSync(path) ? readFileSync(path, "utf8") : undefined
  if (text === undefined) return undefined
  // The file's own personal email also counts (it may differ from the default file's).
  const own = parseDotenv(text).get(PERSONAL_EMAIL)
  if (own && personal && own.trim().toLowerCase() !== personal.trim().toLowerCase()) agentCredentials({ ...guarded, [PERSONAL_EMAIL]: own }, text)
  return agentCredentials(guarded, text)
}

const main = async (argv: ReadonlyArray<string>): Promise<number> => {
  const [command, ...rest] = argv
  const value = (flag: string) => (rest.includes(flag) ? rest[rest.indexOf(flag) + 1] : undefined)
  if (command === "generate") {
    const tag = value("--tag")
    if (!tag) throw new Error("--tag vX.Y.Z")
    const spec = generate(value("--repo") ?? REPO_ROOT, tag)
    mkdirSync(SPEC_DIR, { recursive: true })
    const out = value("--out") ?? join(SPEC_DIR, `${tag}.json`)
    writeFileSync(out, `${JSON.stringify(spec, null, 2)}\n`)
    const reads = spec.requests.filter((r) => r.mode === "read").length
    console.log(`wrote ${out}: ${spec.requests.length} requests from ${tag} (${spec.sha.slice(0, 12)}): ${reads} reads, ${spec.requests.length - reads} shape-only, ${spec.skipped.length} literals skipped`)
    return 0
  }
  if (command === "revisions") {
    const r = webRevisions()
    console.log(JSON.stringify(r, null, 2))
    return r.relation === "same" || r.relation === "newer" ? 0 : 1
  }
  if (command === "replay") {
    const change = value("--change")
    if (!change) throw new Error("--change <compat change key> (compat.ts check prints it)")
    const spec = value("--spec") ? (JSON.parse(readFileSync(value("--spec")!, "utf8")) as Spec) : newestSpec()
    if (!spec) throw new Error(`no spec in ${SPEC_DIR}; run generate first`)
    const origin = value("--origin") ?? STAGING_ORIGIN
    const creds = rest.includes("--unauthenticated") ? undefined : loadCredentials(process.env, value("--credentials"))
    if (!creds && !rest.includes("--unauthenticated")) throw new Error(`no agent credentials (${AGENT.join(", ")}) in the environment or ${value("--credentials") ?? DEFAULT_CREDENTIALS}; pass --unauthenticated for a route-only probe`)
    const supplied = value("--revisions-json")
    const revisions: Revisions = supplied ? { ...(JSON.parse(supplied) as Revisions), source: `supplied by the operator (${(JSON.parse(supplied) as Revisions).source ?? "unknown"})` } : webRevisions()
    const result = await authenticatedReplay(spec, origin, creds, { gaps: readGaps(), revisions })
    for (const l of result.lines) console.log(l)
    for (const w of result.warnings) console.log(`warning: ${w}`)
    console.log(`counts: ${JSON.stringify(result.counts)}`)
    console.log(`web revisions: staging ${revisions.staging.sha ?? revisions.staging.error} production ${revisions.production.sha ?? revisions.production.error}: staging is ${revisions.relation}`)
    const receipt = {
      action: "compat-smoke" as const,
      what: `${result.authenticated ? "signed-in (agent profile)" : "unauthenticated"} replay of ${spec.requests.length} ${spec.tag} requests against ${origin}: ${result.failures.length} failed`,
      tree: "compat",
      target: value("--target") ?? "production",
      result: result.ok ? ("pass" as const) : ("fail" as const),
      at: new Date().toISOString(),
      setHash: change,
      release: spec.tag,
      releaseSha: spec.sha,
      authenticated: result.authenticated,
      counts: result.counts,
      shapeOnly: result.shapeOnly,
      revisions,
      runId: runIdOf(),
      by: actor(),
      ...(result.failures.length ? { errors: result.failures } : {}),
      ...(result.warnings.length ? { warnings: result.warnings } : {}),
    }
    const file = writeReceipt(receiptsDir(), receipt)
    console.log(`bd-summary: ${summaryLine(receipt, file)} authenticated=${result.authenticated} staging=${revisions.relation}`)
    return result.ok ? 0 : 1
  }
  console.error("usage: cmux-old.ts generate --tag vX.Y.Z | replay --change KEY | revisions")
  return 2
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))
