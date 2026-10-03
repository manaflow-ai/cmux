import { describe, expect, test } from "bun:test"
import {
  defaultActionFor,
  grantFor,
  isValidPattern,
  matchPattern,
  opClassForGraphql,
  opClassForHttp,
  opClassForMcp,
  patternSpecificity,
  resolveEffectivePolicy,
  stricter,
  type PolicyRule
} from "../src/policy.ts"

describe("defaults from the spec", () => {
  test("HTTP methods map to op classes", () => {
    expect(["GET", "head", "OPTIONS"].map(opClassForHttp)).toEqual(["read", "read", "read"])
    expect(["post", "put", "patch"].map(opClassForHttp)).toEqual(["mutate-shared", "mutate-shared", "mutate-shared"])
    expect(opClassForHttp("DELETE")).toBe("destructive")
  })

  test("GraphQL destructive verbs need a word boundary", () => {
    expect(opClassForGraphql("query", "deleteEverything")).toBe("read")
    expect(opClassForGraphql("mutation", "deleteUser")).toBe("destructive")
    expect(opClassForGraphql("mutation", "remove_member")).toBe("destructive")
    expect(opClassForGraphql("mutation", "removed")).toBe("mutate-shared")
    expect(opClassForGraphql("mutation", "dropdownSave")).toBe("mutate-shared")
  })

  test("MCP hints", () => {
    expect(opClassForMcp({ readOnlyHint: true, destructiveHint: true })).toBe("read")
    expect(opClassForMcp({ destructiveHint: true })).toBe("destructive")
    expect(opClassForMcp({ destructiveHint: false })).toBe("mutate-shared")
    expect(opClassForMcp(undefined)).toBe("mutate-shared")
  })

  test("op class to action and grant", () => {
    expect(defaultActionFor("read")).toBe("allow")
    expect(defaultActionFor("mutate-own")).toBe("allow")
    expect(defaultActionFor("mutate-shared")).toBe("ask")
    expect(defaultActionFor("send-external")).toBe("ask")
    expect(defaultActionFor("execute")).toBe("ask")
    expect(defaultActionFor("destructive")).toBe("block")
    expect(defaultActionFor("money")).toBe("block")
    expect(grantFor("allow")).toEqual({ granted: true, approval: "none" })
    expect(grantFor("ask")).toEqual({ granted: true, approval: "per_call" })
    expect(grantFor("block")).toBeNull()
  })
})

describe("patterns", () => {
  test("exact, subtree and one-segment wildcards", () => {
    expect(matchPattern("*", "a.b.c")).toBe(true)
    expect(matchPattern("tb.projects.list", "tb.projects.list")).toBe(true)
    expect(matchPattern("tb.projects", "tb.projects.list")).toBe(false)
    expect(matchPattern("tb.projects.*", "tb.projects.list")).toBe(true)
    expect(matchPattern("tb.projects.*", "tb.projects")).toBe(true)
    expect(matchPattern("tb.*.delete", "tb.projects.delete")).toBe(true)
    expect(matchPattern("tb.*.delete", "tb.delete")).toBe(false)
  })

  test("validation and specificity", () => {
    expect(["*", "a", "a.*", "a.*.b"].every(isValidPattern)).toBe(true)
    expect(["", ".a", "a.", "a..b", "*.a", "a.b*"].some(isValidPattern)).toBe(false)
    expect(["*", "a.*", "a.b.*", "a.b", "a.b.c"].map(patternSpecificity)).toEqual([0, 2, 4, 5, 7])
  })
})

describe("resolution", () => {
  const rule = (id: string, owner: "team" | "user", pattern: string, action: PolicyRule["action"]): PolicyRule => ({ id, owner, pattern, action })

  test("no rule: the spec default applies", () => {
    expect(resolveEffectivePolicy("tb.projects.list", [], "allow")).toEqual({ action: "allow", source: "default" })
  })

  test("within one owner the most specific rule wins", () => {
    const rules = [rule("r1", "user", "tb.*", "block"), rule("r2", "user", "tb.projects.list", "allow")]
    expect(resolveEffectivePolicy("tb.projects.list", rules, "ask")).toMatchObject({ action: "allow", source: "user", ruleId: "r2" })
    expect(resolveEffectivePolicy("tb.tasks.list", rules, "allow")).toMatchObject({ action: "block", ruleId: "r1" })
  })

  test("across owners the most restrictive wins: a user cannot loosen a team rule", () => {
    const rules = [rule("t1", "team", "tb.projects.*", "ask"), rule("u1", "user", "tb.projects.delete", "allow")]
    expect(resolveEffectivePolicy("tb.projects.delete", rules, "block")).toMatchObject({ action: "ask", source: "team" })
    const tighter = [rule("t1", "team", "tb.*", "ask"), rule("u1", "user", "tb.projects.list", "block")]
    expect(resolveEffectivePolicy("tb.projects.list", tighter, "allow")).toMatchObject({ action: "block", source: "user" })
  })

  test("a rule replaces the default even when it is looser", () => {
    expect(resolveEffectivePolicy("tb.projects.delete", [rule("u", "user", "tb.projects.delete", "allow")], "block").action).toBe("allow")
  })

  test("stricter", () => {
    expect(stricter("allow", "ask")).toBe("ask")
    expect(stricter("block", "ask")).toBe("block")
  })
})
