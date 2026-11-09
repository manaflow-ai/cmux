// The deploy check's two retries (cmuxterm-hq goals/cloud-deploy-checked.md): cloud-journey-ci.sh runs a
// failed journey once more and judges the second run, and db-release's connect waits out a full database.
// No network and no secret: a fake `bun` stands in for cloud-journey.ts, a fake connect for Postgres.
import { describe, expect, it } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { connectBusy, connectRetrying, type Sql } from "./release/runner.ts"

const script = join(import.meta.dir, "cloud-journey-ci.sh")

/** Runs cloud-journey-ci.sh with a fake bun whose journey runs exit with RUNS in turn and whose compare exits COMPARE. */
const wrapper = (runs: number[], phase: string, compare = 0) => {
  const dir = mkdtempSync(join(tmpdir(), "journey-retry-"))
  const bin = join(dir, "bin")
  Bun.spawnSync(["mkdir", "-p", bin])
  writeFileSync(join(dir, "runs"), runs.join("\n") + "\n")
  // A journey run writes its summary to --out and takes the next exit code; --compare exits COMPARE.
  writeFileSync(join(bin, "bun"), `#!/usr/bin/env bash
if [ "$2" = --compare ]; then echo compared; exit ${compare}; fi
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
mkdir -p "$out"; code="$(head -n1 "${dir}/runs")"; sed -i.bak 1d "${dir}/runs"
echo "| step | exit $code |" > "$out/summary.md"; echo "{}" > "$out/journey.json"
echo run >> "${dir}/calls"; exit "$code"
`)
  chmodSync(join(bin, "bun"), 0o755)
  const summary = join(dir, "summary.md")
  const r = Bun.spawnSync(["bash", script], {
    env: { PATH: `${bin}:${process.env.PATH}`, TARGET: "staging", JOURNEY_PHASE: phase, RUNNER_TEMP: dir, GITHUB_STEP_SUMMARY: summary,
      CMUX_DOGFOOD_STACK_EMAIL: "e", CMUX_DOGFOOD_STACK_PASSWORD: "p", JOURNEY_RETRY_DELAY_S: "0" },
  })
  let calls = 0
  try { calls = readFileSync(join(dir, "calls"), "utf8").trim().split("\n").length } catch {}
  return { code: r.exitCode, out: r.stdout.toString(), summary: readFileSync(summary, "utf8"), calls }
}

describe("cloud-journey-ci.sh retry", () => {
  it("a run that fails once and passes again is a pass, with a warning and both summaries", () => {
    const r = wrapper([1, 0], "after")
    expect(r.calls).toBe(2)
    expect(r.code).toBe(0)
    expect(r.out).toContain("title=Cloud journey retried::")
    expect(r.out).toContain("title=Cloud journey verdict::target=staging result=pass")
    expect(r.summary).toContain("first run, failed; run again")
  })
  it("a run that passes first is never run again", () => {
    const r = wrapper([0], "after")
    expect(r.calls).toBe(1)
    expect(r.out).not.toContain("retried")
    expect(r.out).toContain("result=pass")
  })
  it("a run that fails twice is red; a compare that finds a new red still says regressed (exit 3, rollback)", () => {
    expect(wrapper([1, 1], "").out).toContain("result=red")
    const r = wrapper([1, 1], "after", 3)
    expect(r.calls).toBe(2)
    expect(r.code).toBe(3)
    expect(r.out).toContain("result=regressed")
  })
})

describe("db-release connect retry", () => {
  const fake = { query: async () => [], end: async () => {} } as Sql
  const busy = Object.assign(new Error("remaining connection slots are reserved for roles with the SUPERUSER attribute"), { code: "53300" })
  it("waits out a full database", async () => {
    let n = 0
    const waits: number[] = []
    const sql = await connectRetrying(async () => { if (n++ < 2) throw busy; return fake }, "u", [1, 2, 3], async (ms) => { waits.push(ms) }, () => {})
    expect(sql).toBe(fake)
    expect(waits).toEqual([1, 2])
  })
  it("gives up after its waits, and never retries another error", async () => {
    await expect(connectRetrying(async () => { throw busy }, "u", [1], async () => {}, () => {})).rejects.toThrow("connection slots")
    let n = 0
    const denied = Object.assign(new Error("password authentication failed"), { code: "28P01" })
    await expect(connectRetrying(async () => { n++; throw denied }, "u", [1, 2], async () => {}, () => {})).rejects.toThrow("password")
    expect(n).toBe(1)
    expect(connectBusy({ code: "57P03" })).toBe(true)
    expect(connectBusy(null)).toBe(false)
  })
})
