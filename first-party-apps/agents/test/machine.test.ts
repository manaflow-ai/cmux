import { describe, expect, test } from "bun:test"
import { capabilitySummary, sanitizeMachine, type Machine } from "../src/model/entries.ts"

describe("machine capability summaries", () => {
  test("rejects non-array capability payloads without crashing", () => {
    for (const capabilities of [{ terminal: true }, "terminal", 42, null]) {
      const machine = { id: "remote", name: "remote", origin: "server", status: "running", capabilities } as unknown as Machine
      expect(sanitizeMachine(machine).capabilities).toEqual([])
      expect(capabilitySummary(machine)).toBeNull()
    }
  })

  test("accepts only strings inside capability arrays", () => {
    const machine = { capabilities: [true, false, null, 123, {}, "terminal", "terminal", "agent_session"] } as unknown as Machine
    expect(sanitizeMachine(machine).capabilities).toEqual(["terminal", "agent_session"])
    expect(capabilitySummary(machine)).toBe("terminal · agent session")
  })

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

  test("sanitizes owner metadata before it enters app state", () => {
    const machine = sanitizeMachine({
      id: "remote",
      name: "remote",
      origin: "server",
      status: "running",
      platform: { os: "linux", arch: "../../secret" },
      capabilities: ["terminal", "../../secret", "agent_session"]
    })
    expect(machine.platform).toEqual({ os: "linux", arch: null })
    expect(machine.capabilities).toEqual(["terminal", "agent_session"])
  })
})
