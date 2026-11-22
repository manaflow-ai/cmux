import { describe, expect, test } from "bun:test"
import { answerButtons, approveAnswer, choiceAnswer, choiceComplete, fieldsAnswer, fieldsOf, formOf, toggleOption } from "../src/answers.ts"
import { feedItems, fid } from "./fixtures.ts"

const byId = (name: string) => feedItems(0).find((i) => i.id === fid(name))!

describe("forms per kind", () => {
  test("built-in kinds map to their forms; closed requests and notices have none", () => {
    expect(formOf(byId("retrychoice"))).toMatchObject({ kind: "choice", oneTap: true })
    expect(formOf(byId("npminstall"))).toEqual({ kind: "approve", summary: "Install a charting package", command: "npm install --save chart-kit", scopes: ["once", "session"] })
    expect(formOf(byId("signin"))).toMatchObject({ kind: "browser", origin: "https://staging.example.com" })
    expect(formOf(byId("volumename"))).toEqual({ kind: "fields", fields: [{ key: "volume", title: "Volume name", type: "string", required: true }] })
    expect(formOf(byId("dropdbs"))).toMatchObject({ kind: "confirm", confirmLabel: "Delete", destructive: true })
    expect(formOf(byId("refunds"))).toMatchObject({ kind: "review", subject: "pr" })
    expect(formOf(byId("darkmode"))).toEqual({ kind: "none" })
    expect(formOf({ ...byId("npminstall"), state: "answered" })).toEqual({ kind: "none" })
    expect(formOf({ ...byId("npminstall"), kind: "file", prompt: { purpose: "x", accept: [], multiple: false, max_bytes: 1 } })).toEqual({ kind: "unsupported" })
  })

  test("custom kinds: poster buttons with values, or a flat answer schema", () => {
    const base = byId("npminstall")
    const custom = { ...base, kind: "x-example.deploy", actions: [{ id: "go", label: "Deploy", answer: { go: true } }, { id: "logs", label: "Logs" }] }
    expect(formOf(custom)).toEqual({ kind: "none" })
    expect(answerButtons(custom).map((a) => a.label)).toEqual(["Deploy"])
    const schema = { type: "object", properties: { env: { enum: ["staging", "prod"] }, dry: { type: "boolean" } }, required: ["env"] }
    expect(formOf({ ...base, kind: "x-example.deploy", answer_schema: schema })).toMatchObject({ kind: "fields" })
    expect(fieldsOf({ type: "object", properties: { nested: { type: "object" } } })).toBeNull()
  })
})

describe("answer values", () => {
  test("approve, choice and fields follow the kind registry's shapes", () => {
    expect(approveAnswer("allow")).toEqual({ decision: "allow", scope: "once" })
    expect(approveAnswer("allow", "session")).toEqual({ decision: "allow", scope: "session" })
    expect(approveAnswer("deny")).toEqual({ decision: "deny" })
    const q = { id: "q", question: "?", options: [{ id: "a", label: "A" }, { id: "b", label: "B" }], multi: true, allow_other: true }
    expect(toggleOption(q, ["a"], "b")).toEqual(["a", "b"])
    expect(toggleOption({ ...q, multi: false }, ["a"], "b")).toEqual(["b"])
    expect(choiceComplete([q], {}, { q: " " })).toBe(false)
    expect(choiceComplete([q], {}, { q: "c" })).toBe(true)
    expect(choiceAnswer([q], { q: ["a"] }, { q: " custom " })).toEqual({ answers: { q: { selected: ["a"], other: "custom" } } })
    const fields = fieldsOf({ type: "object", properties: { n: { type: "integer" }, s: { type: "string" }, b: { type: "boolean" }, e: { type: "array", items: { enum: ["x", "y"] } } }, required: ["n", "b"] })!
    expect(fieldsAnswer(fields, { n: "2.5" }).missing).toEqual(["n"])
    expect(fieldsAnswer(fields, { n: " 3 ", s: "", e: ["y"] })).toEqual({ value: { n: 3, b: false, e: ["y"] }, missing: [] })
  })
})
