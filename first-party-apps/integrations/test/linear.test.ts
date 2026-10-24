import { describe, expect, test } from "bun:test"
import { normalizeTeams } from "../src/model/linear.ts"

describe("Linear teams response", () => {
  test("keeps the public shape, trims text and deduplicates ids", () => {
    expect(normalizeTeams({
      teams: [
        { id: " team_1 ", key: " ENG ", name: " Engineering ", privateToken: "do-not-return" },
        { id: "team_1", key: "DUP", name: "Duplicate" },
        { id: "team_2", key: "OPS", name: "Operations" },
        { id: "team_bad", key: "", name: "Incomplete" },
        null
      ]
    })).toEqual({ teams: [
      { id: "team_1", key: "ENG", name: "Engineering" },
      { id: "team_2", key: "OPS", name: "Operations" }
    ] })
  })

  test("rejects a response without a teams array", () => {
    expect(() => normalizeTeams({ data: {} })).toThrow("teams array")
    expect(() => normalizeTeams(null)).toThrow("teams array")
  })

  test("accepts an empty array and skips malformed rows", () => {
    expect(normalizeTeams({ teams: [{ id: 1, key: "NO", name: "No" }, {}, false] })).toEqual({ teams: [] })
    expect(normalizeTeams({ teams: [] })).toEqual({ teams: [] })
  })
})
