/** promote-lib.ts with a fake image provider: smoke is the only provider call, and it is recorded. */
import { describe, expect, it } from "bun:test"
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { ledgerClones, promote, readSmokeOutcome, readVar, type SmokeOutcome } from "../promote-lib.ts"
import { readReceipts } from "../receipts.ts"
import { REAL } from "./helpers.ts"

const PASSED = "sh-05e11db6222747e9b75b3be37bf8de0c" // hostrun5, PASSED in the real dev.json history
const WRANGLER = "backend/apps/api/wrangler.jsonc"

const setup = (extraHistory: Array<Record<string, unknown>> = []) => {
  const root = mkdtempSync(join(tmpdir(), "rails-promote-"))
  mkdirSync(join(root, "images/cmux-vm/channels"), { recursive: true })
  mkdirSync(join(root, "backend/apps/api"), { recursive: true })
  const dev = JSON.parse(readFileSync(REAL("images/cmux-vm/channels/dev.json"), "utf8"))
  dev.history.push(...extraHistory)
  writeFileSync(join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify(dev, null, 2))
  cpSync(REAL(WRANGLER), join(root, WRANGLER))
  const receipts = mkdtempSync(join(tmpdir(), "rails-promote-receipts-"))
  const smokes: Array<[string, string]> = []
  const resolved: Record<string, string> = { "cmuxnp-dev-vmimg-hostrun5": PASSED, "cmuxnp-dev-vmimg-hostrun6": "sh-0000000000000000000000000000hr06", "cmuxnp-stg-vmimg-hostrun8": "sh-000000000000000000000000000stg08", "cmuxnp-prod-vmimg-hostrun8": "sh-00000000000000000000000000prod08", "cmuxnp-dev-vmimg-teamvm4": "sh-0000000000000000000000000000tv04", "cmuxnp-dev-vmimg-teamvm3": "sh-teamvm3" }
  let outcome: SmokeOutcome = { passed: true, created: [{ id: "vm-a", name: "cmuxnp-dev-vmimg-promote-smoke-1" }, { id: "vm-b", name: "cmuxnp-dev-vmimg-promote-smoke-2" }], live: [], detail: "fake smoke" }
  const logs: Array<string> = []
  const errors: Array<string> = []
  const run = (...argv: Array<string>) =>
    promote(argv, {
      root,
      now: () => new Date("2026-10-08T12:00:00Z"),
      smoke: async (id, tag) => {
        smokes.push([id, tag])
        return outcome
      },
      resolve: async (name) => resolved[name],
      log: (l) => logs.push(l),
      error: (l) => errors.push(l),
      by: "test",
      env: { CMUX_RELEASE_RECEIPTS_DIR: receipts, CMUX_RELEASE_LATEST_STABLE: "v0.65.0" },
    })
  return {
    root,
    receipts,
    smokes,
    logs,
    errors,
    run,
    setOutcome: (o: SmokeOutcome) => (outcome = o),
    resolved,
    wrangler: () => readFileSync(join(root, WRANGLER), "utf8"),
    channel: (c: string) => JSON.parse(readFileSync(join(root, "images/cmux-vm/channels", `${c}.json`), "utf8")),
  }
}

const hostrun6 = { snapshot: "cmuxnp-dev-vmimg-hostrun6", snapshot_id: "sh-0000000000000000000000000000hr06", smoke: { result: "PASSED", at: "2026-10-08" } }
const failed7 = { snapshot: "cmuxnp-dev-vmimg-hostrun7", snapshot_id: "sh-0000000000000000000000000000hr07", smoke: { result: "FAILED", at: "2026-10-08" } }
const stg = {
  snapshot: "cmuxnp-dev-vmimg-hostrun8",
  snapshot_id: "sh-0000000000000000000000000000hr08",
  smoke: { result: "PASSED" },
  names: { staging: { snapshot: "cmuxnp-stg-vmimg-hostrun8", snapshot_id: "sh-000000000000000000000000000stg08" }, production: { snapshot: "cmuxnp-prod-vmimg-hostrun8", snapshot_id: "sh-00000000000000000000000000prod08" } },
}
const teamvm = { snapshot: "cmuxnp-dev-vmimg-teamvm4", snapshot_id: "sh-0000000000000000000000000000tv04", smoke: { result: "PASSED" } }

describe("refusals (no provider call, no file change)", () => {
  it("refuses an id that is not in dev.json history", async () => {
    const t = setup()
    const before = t.wrangler()
    expect(await t.run("--channel", "dev", "--snapshot", "sh-unknown")).toBe(1)
    expect(t.errors.at(-1)).toContain("not in channels/dev.json history")
    expect(t.smokes).toEqual([])
    expect(t.wrangler()).toBe(before)
  })
  it("refuses an id whose recorded smoke is not PASSED", async () => {
    const t = setup([failed7])
    expect(await t.run("--channel", "dev", "--snapshot", failed7.snapshot_id)).toBe(1)
    expect(t.errors.at(-1)).toContain("FAILED")
    expect(t.smokes).toEqual([])
  })
  it("refuses a dev-named Cloud snapshot for staging (the Worker would refuse every create)", async () => {
    const t = setup()
    expect(await t.run("--channel", "staging", "--snapshot", PASSED)).toBe(1)
    expect(t.errors.at(-1)).toContain("boots only cmuxnp-stg-vmimg-")
    expect(t.smokes).toEqual([])
  })
})

describe("the fresh-clone smoke decides", () => {
  it("smoke FAILED: refused, files unchanged", async () => {
    const t = setup([hostrun6])
    const before = t.wrangler()
    t.setOutcome({ passed: false, created: [{ id: "vm-a", name: "cmuxnp-dev-vmimg-x-smoke-1" }], live: [], detail: "daemon-bound failed" })
    expect(await t.run("--channel", "dev", "--snapshot", hostrun6.snapshot_id)).toBe(1)
    expect(t.smokes).toEqual([[hostrun6.snapshot_id, "promote202610081200"]])
    expect(t.wrangler()).toBe(before)
  })
  it("a clone left running: refused and named by id", async () => {
    const t = setup([hostrun6])
    t.setOutcome({ passed: true, created: [{ id: "vm-a", name: "cmuxnp-dev-vmimg-x-smoke-1" }], live: [{ id: "vm-a", name: "cmuxnp-dev-vmimg-x-smoke-1" }], detail: "" })
    expect(await t.run("--channel", "dev", "--snapshot", hostrun6.snapshot_id)).toBe(1)
    expect(t.errors.join()).toContain("vm-a")
  })
  it("a clone outside cmuxnp-dev-: refused", async () => {
    const t = setup([hostrun6])
    t.setOutcome({ passed: true, created: [{ id: "vm-z", name: "user-vm" }], live: [], detail: "" })
    expect(await t.run("--channel", "dev", "--snapshot", hostrun6.snapshot_id)).toBe(1)
    expect(t.errors.join()).toContain("outside the cmuxnp-dev- prefix")
  })
})

describe("promote and roll back", () => {
  it("dev CLOUD_FREESTYLE_SNAPSHOT: sets env.development, keeps previous, writes a receipt; --rollback restores it", async () => {
    const t = setup([hostrun6])
    expect(readVar(t.wrangler(), "development", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-hostrun5")
    expect(await t.run("--channel", "dev", "--snapshot", hostrun6.snapshot_id, "--worker-version", "ver-123")).toBe(0)
    expect(readVar(t.wrangler(), "development", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-hostrun6")
    const dev = t.channel("dev")
    expect(dev.snapshot_id).toBe(hostrun6.snapshot_id)
    expect(dev.previous).toEqual({ snapshot: "cmuxnp-dev-vmimg-hostrun5", snapshot_id: PASSED })
    expect(typeof dev.previous_notes).toBe("string") // the old prose is kept
    expect(dev.history.length).toBe(2) // history untouched
    const receipt = readReceipts(t.receipts).at(-1)!
    expect(receipt.what).toContain("cmuxnp-dev-vmimg-hostrun5 -> cmuxnp-dev-vmimg-hostrun6")
    expect(receipt.before).toEqual([`cmuxnp-dev-vmimg-hostrun5 ${PASSED}`])
    expect(receipt.rollback?.join("\n")).toContain("wrangler rollback ver-123 --name cmux-api-development")
    expect(t.smokes.length).toBe(1)

    expect(await t.run("--channel", "dev", "--rollback")).toBe(0)
    expect(readVar(t.wrangler(), "development", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-hostrun5")
    expect(t.channel("dev").snapshot_id).toBe(PASSED)
    expect(t.smokes.length).toBe(1) // rollback needs no smoke
  })

  it("staging and production: inserts the var where the env had none, from the per-channel name", async () => {
    const t = setup([stg])
    expect(readVar(t.wrangler(), "staging", "CLOUD_FREESTYLE_SNAPSHOT")).toBeUndefined()
    expect(await t.run("--channel", "staging", "--snapshot", stg.snapshot_id)).toBe(0)
    expect(readVar(t.wrangler(), "staging", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-stg-vmimg-hostrun8")
    expect(t.channel("staging").previous).toBeNull()
    expect(await t.run("--channel", "production", "--snapshot", stg.snapshot_id)).toBe(1) // no cmux-old compat receipts yet
    expect(t.errors.join("\n")).toContain("no passing cmux-old client smoke")
    const { writeReceipt } = await import("../receipts.ts")
    for (const action of ["compat-static", "compat-smoke"] as const)
      writeReceipt(t.receipts, { action, tree: "images", target: "production", result: "pass", at: "2026-10-08T11:00:00.000Z", setHash: `image:CLOUD_FREESTYLE_SNAPSHOT:${stg.snapshot_id}`, release: "v0.65.0", by: "test" })
    expect(await t.run("--channel", "production", "--snapshot", stg.snapshot_id)).toBe(0)
    expect(readVar(t.wrangler(), "production", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-prod-vmimg-hostrun8")
    expect(readVar(t.wrangler(), "development", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-hostrun5") // other envs untouched
    expect(await t.run("--channel", "staging", "--rollback")).toBe(1) // nothing before the first promotion
    expect(t.errors.at(-1)).toContain("no previous")
  })

  it("TEAM_VM_SNAPSHOT: its own pointer (team_vm) and its own rollback; the Cloud var is untouched", async () => {
    const t = setup([teamvm])
    expect(await t.run("--channel", "dev", "--var", "TEAM_VM_SNAPSHOT", "--snapshot", teamvm.snapshot_id)).toBe(0)
    expect(readVar(t.wrangler(), "development", "TEAM_VM_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-teamvm4")
    expect(readVar(t.wrangler(), "development", "CLOUD_FREESTYLE_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-hostrun5")
    const dev = t.channel("dev")
    expect(dev.team_vm.previous).toEqual({ snapshot: "cmuxnp-dev-vmimg-teamvm3", snapshot_id: null })
    expect(dev.snapshot).toBe("cmuxnp-dev-vmimg-hostrun5")
    expect(await t.run("--channel", "dev", "--var", "TEAM_VM_SNAPSHOT", "--rollback")).toBe(0)
    expect(readVar(t.wrangler(), "development", "TEAM_VM_SNAPSHOT")).toBe("cmuxnp-dev-vmimg-teamvm3")
  })

  it("the smoke ledger reader counts a clone without a deleted row as live", () => {
    const tsv = "vm-1\tvm\tcmuxnp-dev-vmimg-t-smoke-1\t2026\tcreated\nvm-1\tvm\tcmuxnp-dev-vmimg-t-smoke-1\t2026\tdeleted\nvm-2\tvm\tcmuxnp-dev-vmimg-t-smoke-2\t2026\tcreated\n"
    expect(ledgerClones(tsv)).toEqual({ created: [{ id: "vm-1", name: "cmuxnp-dev-vmimg-t-smoke-1" }, { id: "vm-2", name: "cmuxnp-dev-vmimg-t-smoke-2" }], live: [{ id: "vm-2", name: "cmuxnp-dev-vmimg-t-smoke-2" }] })
  })

  it("P2-12 smokes the channel's own snapshot id, records the result in history, and refuses a name that resolves to another id", async () => {
    const t = setup([stg])
    expect(await t.run("--channel", "staging", "--snapshot", stg.snapshot_id)).toBe(0)
    expect(t.smokes.map(([id]) => id)).toEqual(["sh-000000000000000000000000000stg08"])
    const entry = t.channel("dev").history.find((h: { snapshot_id: string }) => h.snapshot_id === stg.snapshot_id)
    expect(entry.promotion_smokes).toEqual([expect.objectContaining({ channel: "staging", snapshot_id: "sh-000000000000000000000000000stg08", result: "PASSED" })])
    t.resolved["cmuxnp-prod-vmimg-hostrun8"] = "sh-someoneelse"
    const { writeReceipt } = await import("../receipts.ts")
    for (const action of ["compat-static", "compat-smoke"] as const)
      writeReceipt(t.receipts, { action, tree: "images", target: "production", result: "pass", at: "2026-10-08T11:00:00.000Z", setHash: `image:CLOUD_FREESTYLE_SNAPSHOT:${stg.snapshot_id}`, release: "v0.65.0", by: "test" })
    expect(await t.run("--channel", "production", "--snapshot", stg.snapshot_id)).toBe(1)
    expect(t.errors.at(-1)).toContain("resolves to sh-someoneelse")
  })

  it("P3 a smoke that wrote no ledger does not pass (its clones are unknown)", () => {
    const empty = mkdtempSync(join(tmpdir(), "rails-noledger-"))
    const outcome = readSmokeOutcome(empty, 0, "t")
    expect(outcome.passed).toBe(false)
    expect(outcome.detail).toContain("no ledger")
  })
})
