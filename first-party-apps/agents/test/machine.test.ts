import { describe, expect, test } from "bun:test"
import { capabilitySummary, type Machine } from "../src/model/entries.ts"

describe("machine capability summaries", () => {
  test("deduplicates and formats stable capability names", () => {
    const machine: Machine = { id: "local", name: "local", origin: "local", status: "running", capabilities: ["terminal", "agent_session", "terminal"] }
    expect(capabilitySummary(machine)).toBe("terminal · agent session")
  })

  test("drops malformed names and bounds the display", () => {
    const machine: Machine = {
      id: "remote",
      name: "remote",
      origin: "server",
      status: "running",
      capabilities: ["bad name", "also/bad", ...Array.from({ length: 10 }, (_, i) => `cap-${i}`)]
    }
    expect(capabilitySummary(machine)).toBe("cap-0 · cap-1 · cap-2 · cap-3 · cap-4 · cap-5 · cap-6 · cap-7")
  })
})
