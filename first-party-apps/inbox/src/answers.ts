// Answer values for the built-in request kinds (pure). Shapes follow the
// feed's kind registry (backend/packages/protocol/src/feed-kinds.ts); the
// owner validates every answer again.

import type { FeedItem } from "./feed.ts"

export interface ChoiceQuestion {
  id: string
  question: string
  header?: string
  options: Array<{ id: string; label: string; description?: string }>
  multi: boolean
  allow_other: boolean
}

export type Field =
  | { key: string; title: string; type: "string" | "number" | "integer"; required: boolean }
  | { key: string; title: string; type: "boolean"; required: boolean }
  | { key: string; title: string; type: "enum"; options: string[]; multi: boolean; required: boolean }

/** How the view answers an item. */
export type Form =
  | { kind: "none" }
  | { kind: "question"; question: string; suggestions: string[] }
  | { kind: "choice"; questions: ChoiceQuestion[]; oneTap: boolean }
  | { kind: "approve"; summary: string; command: string | null; scopes: Array<"once" | "session" | "always"> }
  | { kind: "confirm"; statement: string; confirmLabel: string | null; cancelLabel: string | null; destructive: boolean }
  | { kind: "browser"; reason: string; origin: string }
  | { kind: "review"; subject: string; ref: string }
  | { kind: "handoff"; reason: string }
  | { kind: "fields"; fields: Field[] }
  | { kind: "unsupported" }

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {})
const str = (v: unknown) => (typeof v === "string" ? v : "")
const strs = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [])

/** Flat-object fields of an `input` schema or a custom kind's `answer_schema`; null when the schema is not flat. */
export function fieldsOf(schema: unknown): Field[] | null {
  const s = obj(schema)
  if (s.type !== "object") return null
  const required = new Set(strs(s.required))
  const out: Field[] = []
  for (const [key, raw] of Object.entries(obj(s.properties))) {
    const p = obj(raw)
    const title = str(p.title) || str(p.description) || key
    const req = required.has(key)
    if (Array.isArray(p.enum)) out.push({ key, title, type: "enum", options: strs(p.enum), multi: false, required: req })
    else if (p.type === "array" && Array.isArray(obj(p.items).enum)) out.push({ key, title, type: "enum", options: strs(obj(p.items).enum), multi: true, required: req })
    else if (p.type === "string" || p.type === "number" || p.type === "integer" || p.type === "boolean") out.push({ key, title, type: p.type, required: req })
    else return null
  }
  return out
}

/** The form a request asks for; notices and closed requests have none. */
export function formOf(item: FeedItem): Form {
  if (item.type !== "request" || item.state !== "open") return { kind: "none" }
  const p = obj(item.prompt)
  switch (item.kind) {
    case "question":
      return { kind: "question", question: str(p.question), suggestions: strs(p.suggestions) }
    case "choice": {
      const questions = (Array.isArray(p.questions) ? p.questions : []).map(obj).map((q) => ({
        id: str(q.id),
        question: str(q.question),
        header: str(q.header) || undefined,
        options: (Array.isArray(q.options) ? q.options : []).map(obj).map((o) => ({ id: str(o.id), label: str(o.label), description: str(o.description) || undefined })),
        multi: q.multi === true,
        allow_other: q.allow_other === true
      }))
      const only = questions[0]
      return { kind: "choice", questions, oneTap: questions.length === 1 && !!only && !only.multi && !only.allow_other }
    }
    case "approve": {
      const action = obj(p.action)
      const scopes = strs(p.scopes).filter((s): s is "once" | "session" | "always" => s === "once" || s === "session" || s === "always")
      return { kind: "approve", summary: str(action.summary), command: str(action.command) || null, scopes: scopes.length ? scopes : ["once"] }
    }
    case "confirm":
      return { kind: "confirm", statement: str(p.statement), confirmLabel: str(p.confirm_label) || null, cancelLabel: str(p.cancel_label) || null, destructive: p.destructive === true }
    case "sign-in":
    case "passkey":
      return { kind: "browser", reason: str(p.reason), origin: str(p.origin) }
    case "review":
      return { kind: "review", subject: str(p.subject), ref: str(p.ref) }
    case "handoff":
      return { kind: "handoff", reason: str(p.reason) }
    case "input": {
      const fields = fieldsOf(p.schema)
      return fields ? { kind: "fields", fields } : { kind: "unsupported" }
    }
    case "file":
      // Answering needs a file picked by the user and uploaded as an attachment (README, platform gaps).
      return { kind: "unsupported" }
    default: {
      if (item.actions.some((a) => a.answer !== undefined)) return { kind: "none" }
      const fields = item.kind.startsWith("x-") ? fieldsOf(item.answer_schema) : null
      return fields ? { kind: "fields", fields } : { kind: "unsupported" }
    }
  }
}

/** Poster buttons that answer the request with a fixed value (any kind). */
export const answerButtons = (item: FeedItem) => (item.type === "request" && item.state === "open" ? item.actions.filter((a) => a.answer !== undefined) : [])

/** Poster buttons that only open the context. */
export const openButtons = (item: FeedItem) => item.actions.filter((a) => a.answer === undefined)

export const approveAnswer = (decision: "allow" | "deny", scope?: "once" | "session" | "always") => (decision === "allow" ? { decision, scope: scope ?? "once" } : { decision })

/** `choice` answer from the selected option ids per question (and free text when allowed). */
export function choiceAnswer(questions: ChoiceQuestion[], selected: Record<string, string[]>, other: Record<string, string> = {}) {
  const answers: Record<string, { selected: string[]; other?: string }> = {}
  for (const q of questions) {
    const text = (other[q.id] ?? "").trim()
    answers[q.id] = text && q.allow_other ? { selected: selected[q.id] ?? [], other: text } : { selected: selected[q.id] ?? [] }
  }
  return { answers }
}

/** Every question answered (a selection or free text)? */
export const choiceComplete = (questions: ChoiceQuestion[], selected: Record<string, string[]>, other: Record<string, string> = {}) =>
  questions.every((q) => (selected[q.id]?.length ?? 0) > 0 || (q.allow_other && !!(other[q.id] ?? "").trim()))

/** Toggles an option: single-select questions keep one selection. */
export function toggleOption(q: ChoiceQuestion, current: string[], option: string): string[] {
  if (!q.multi) return current[0] === option ? [] : [option]
  return current.includes(option) ? current.filter((o) => o !== option) : [...current, option]
}

/** A form answer from typed drafts; `missing` names required fields left empty or invalid. */
export function fieldsAnswer(fields: Field[], drafts: Record<string, unknown>): { value: Record<string, unknown>; missing: string[] } {
  const value: Record<string, unknown> = {}
  const missing: string[] = []
  for (const f of fields) {
    const d = drafts[f.key]
    if (f.type === "boolean") {
      if (typeof d === "boolean") value[f.key] = d
      else if (f.required) value[f.key] = false
      continue
    }
    if (f.type === "enum") {
      const picked = Array.isArray(d) ? (d as string[]) : typeof d === "string" ? [d] : []
      if (picked.length) value[f.key] = f.multi ? picked : picked[0]
      else if (f.required) missing.push(f.key)
      continue
    }
    const text = typeof d === "string" ? d.trim() : ""
    if (!text) {
      if (f.required) missing.push(f.key)
      continue
    }
    if (f.type === "string") value[f.key] = text
    else {
      const n = Number(text)
      if (!Number.isFinite(n) || (f.type === "integer" && !Number.isInteger(n))) missing.push(f.key)
      else value[f.key] = n
    }
  }
  return { value, missing }
}
