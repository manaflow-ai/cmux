// Run 46048495695, drop 60 s: one `acp history` read before the fault failed while the client was already streaming
// the turn (step 99), and the probe counted the failed read as 0 turns: "never showed in the chat's history".
import { describe, expect, it } from "bun:test"
import { turnShown } from "./cloud-chaos.ts"

const shownOnce = { started: 1, running: true, status: "running", detail: "" }

describe("turnShown", () => {
  it("a failed read is retried, not counted as no turn", async () => {
    let n = 0
    const r = await turnShown(async () => {
      if (n++ === 0) throw new Error("exec: HTTP 503 vm_unavailable")
      return shownOnce
    }, 1_000, 1)
    expect(r.state.started).toBe(1)
    expect(r.error).toBe("")
  })

  it("a turn that shows late is found within the budget", async () => {
    let n = 0
    const r = await turnShown(async () => (n++ < 3 ? { ...shownOnce, started: 0 } : shownOnce), 1_000, 1)
    expect(r.state.started).toBe(1)
  })

  it("history that never answers names the read error", async () => {
    const r = await turnShown(async () => { throw new Error("acp history unreadable (exit 1): no such session") }, 20, 1)
    expect(r.state.started).toBe(0)
    expect(r.error).toContain("unreadable")
  })

  it("history that answers with no turn reports no error: a truly lost prompt", async () => {
    const r = await turnShown(async () => ({ ...shownOnce, started: 0 }), 20, 1)
    expect(r.state.started).toBe(0)
    expect(r.error).toBe("")
  })
})
