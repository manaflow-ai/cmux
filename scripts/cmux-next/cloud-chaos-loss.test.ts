// Run 46116359583, relay cut: the fault landed after the counting turn (step 100 of 100, running=false) and the row
// read "lost or doubled output" although seq was contiguous and every step arrived once. A missed arm is the probe's
// miss and is named so; it still fails the row, since the fault was never exercised.
import { describe, expect, it } from "bun:test"
import { judgeLoss, type SeqEvent } from "./cloud-chaos.ts"

const turn = (n: number, from = 100): SeqEvent[] => Array.from({ length: n }, (_, i) => ({ seq: from + i, ks: [i + 1], call: `c${i + 1}` }))

describe("judgeLoss", () => {
  it("a clean turn armed mid-way passes", () => {
    const r = judgeLoss({ n: 10, journal: turn(10), client: turn(10), injection: { step: 4, running: true } })
    expect(r.ok).toBe(true)
    expect(r.text).toStartWith("no lost output:")
  })
  it("a fault armed after the turn is a probe miss, not lost output", () => {
    const r = judgeLoss({ n: 10, journal: turn(10), client: turn(10), injection: { step: 10, running: false } })
    expect(r.ok).toBe(false)
    expect(r.text).toStartWith("probe miss: the fault was not armed during counting output (step 10 of 10, running=false); no lost output:")
    expect(r.text).not.toContain("lost or doubled")
  })
  it("a missed arm with a real gap names both", () => {
    const client = turn(10).filter((e) => e.seq !== 105)
    const r = judgeLoss({ n: 10, journal: turn(10), client, injection: { step: 10, running: false } })
    expect(r.ok).toBe(false)
    expect(r.text).toStartWith("probe miss:")
    expect(r.text).toContain("lost or doubled output:")
  })
})
