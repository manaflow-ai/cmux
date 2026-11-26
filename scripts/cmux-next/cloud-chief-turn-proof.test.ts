// The Chief turn proof's verdicts: which faults are staging's or the shared credential's (NOT JUDGED, exit 0) and
// which are the code's (FAIL). The quoted lines are the red runs of 2026-11-25. No network and no secret.
import { describe, expect, it } from "bun:test"
import { infraFault, judge, notJudged, type RunResult } from "./cloud-chief-turn-proof.ts"

const run = (label: string, replies: string[]): RunResult => ({ label, exit: "exit 0", replies, timeout: null, why: "" })

describe("Chief turn proof: infra faults are not judged", () => {
  it("names staging's refusals and resets", () => {
    expect(infraFault('exec: HTTP 503 "vm_unavailable"')).toContain("staging")
    expect(infraFault("ECONNRESET: The socket connection was closed unexpectedly.")).toContain("staging")
    expect(infraFault("The operation timed out. (try 4, 241 s)")).toContain("staging")
    expect(infraFault("create machine: 502 vm_unavailable")).toContain("staging")
    expect(infraFault("still provisioning after 300 s")).toContain("staging")
  })

  it("names the shared credential's limit in the proof's reply", () => {
    const replies = ["(turn failed on claude: You've hit your weekly limit · resets Dec 2, 3am (UTC))"]
    expect(judge("proof", run("proof", replies))).toBe(false)
    expect(infraFault(null, replies)).toContain("shared Claude credential")
  })

  it("does not judge a proof whose exec staging cut, when the resend brought no reply", () => {
    const cut = 'exec: HTTP 503 "vm_unavailable"'
    expect(notJudged(run("control", []), { ...run("proof", []), cut })).toContain("staging")
    expect(notJudged(run("control", []), run("proof", []))).toBeNull()
    expect(notJudged(run("control", []), { ...run("proof", ["(turn failed on claude: not signed in)"]), cut })).toBeNull()
    expect(notJudged(run("control", ["OK"]), { ...run("proof", []), cut })).toBeNull()
    expect(notJudged(run("control", []), run("proof", ["OK"]))).toBeNull()
  })

  it("judges the code's own failures", () => {
    expect(infraFault(null, [])).toBeNull()
    expect(infraFault(null, ["(turn failed on claude: not signed in)"])).toBeNull()
    expect(infraFault("no cmux-tui on the machine: ")).toBeNull()
    expect(infraFault("unpack: exit 2 tar: invalid magic")).toBeNull()
    expect(infraFault("route: exit 5 coderouter.cmux.internal still does not resolve")).toBeNull()
    expect(infraFault("create answered no machine id")).toBeNull()
  })

  it("still passes only the model's own OK", () => {
    expect(judge("proof", run("proof", ["OK"]))).toBe(true)
    expect(judge("control", run("control", []))).toBe(true)
    expect(judge("control", run("control", ["OK"]))).toBe(false)
  })
})
