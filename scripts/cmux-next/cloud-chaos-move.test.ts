// The real-VM move drills' plumbing, without a Cloud machine: the carrier socket outlives its ready line, and a long
// journey's bearer is refreshed in every place that hands it on. Both broke real-VM run 45162400826 (every cell
// unmeasured: the seed pushes found no carrier socket, the later cells a 401).
import { describe, expect, it } from "bun:test"
import { chmodSync, existsSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { CarrierServe, moveVerdict, startSettled } from "./cloud-chaos-move.ts"
import { Api, keepBearerFresh } from "./cloud-journey.ts"

/** A stand-in `cmux carrier serve`: binds nothing, makes the socket file, prints the ready line and, like the real
 * one, ends and removes the socket when its stdin closes. */
const fakeCmux = (dir: string) => {
  const bin = join(dir, "cmux")
  writeFileSync(bin, `#!/usr/bin/env bash
sock=""; while [ $# -gt 0 ]; do [ "$1" = --socket ] && sock="$2"; shift; done
: > "$sock"
echo "{\\"ok\\":true,\\"socket\\":\\"$sock\\",\\"route\\":\\"carrier\\"}" >&2
cat >/dev/null
rm -f "$sock"
`)
  chmodSync(bin, 0o755)
  return bin
}

describe("CarrierServe", () => {
  it("keeps serving after its ready line, and stops when told", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kmm-carrier-"))
    const socket = join(dir, "c0.sock")
    let reads = 0
    const carrier = new CarrierServe("vm_test", socket, fakeCmux(dir), () => { reads++; return { PATH: process.env.PATH } })
    await carrier.start()
    await Bun.sleep(500)
    expect(carrier.proc?.exitCode).toBeNull()
    expect(existsSync(socket)).toBe(true)
    expect(reads).toBe(1)
    carrier.stop()
  })
})

describe("keepBearerFresh", () => {
  it("puts each new token in the client, every handed-on environment and the scrub list", async () => {
    const api = new Api("http://127.0.0.1:1")
    api.bearer = "old"
    const env: Record<string, string | undefined> = { CMUX_CLOUD_ACCESS_TOKEN: "old" }
    api.tokenEnvs.push(env)
    const secrets: string[] = []
    let n = 0
    const stop = keepBearerFresh(api, async () => ({ access: `new${++n}`, refresh: `r${n}` }), secrets, () => undefined, 20)
    await Bun.sleep(70)
    stop()
    expect(n).toBeGreaterThanOrEqual(2)
    expect(api.bearer).toBe(`new${n}`)
    expect(env.CMUX_CLOUD_ACCESS_TOKEN).toBe(`new${n}`)
    expect(secrets).toContain("new1")
    expect(secrets).toContain("r1")
  })

  it("keeps the old token when a sign-in fails", async () => {
    const api = new Api("http://127.0.0.1:1")
    api.bearer = "old"
    const lines: string[] = []
    const stop = keepBearerFresh(api, async () => { throw new Error("Stack sign-in HTTP 500") }, [], (l) => lines.push(l), 20)
    await Bun.sleep(50)
    stop()
    expect(api.bearer).toBe("old")
    expect(lines[0]).toContain("the old token kept")
  })
})

describe("startSettled", () => {
  const refused = new Error('cloud.machine.start: HTTP 200 {"code":"cloud.machine.not_paused","details":{"state":"pausing","refusal":"operation_in_flight"}}')

  it("waits out a pause still in flight, then starts (run 45820934296's pause-src drill)", async () => {
    const states = ["pausing", "pausing", "paused"]
    let starts = 0
    const notes: string[] = []
    await startSettled({
      status: async () => states.shift() ?? "paused",
      start: async () => { if (++starts < 3) throw refused },
    }, "vm_test", (s) => notes.push(s), 60_000, async () => undefined)
    expect(starts).toBe(3)
    expect(notes[0]).toContain("reads pausing")
  })

  it("stops when the machine reads running after a refusal", async () => {
    let starts = 0
    await startSettled({ status: async () => "running", start: async () => { starts++; throw refused } }, "vm_test", () => undefined, 60_000, async () => undefined)
    expect(starts).toBe(1)
  })

  it("throws any other refusal at once", async () => {
    const other = new Error('cloud.machine.start: HTTP 404 {"code":"cloud.machine.not_found"}')
    await expect(startSettled({ status: async () => "unknown", start: async () => { throw other } }, "vm_test", () => undefined, 60_000, async () => undefined)).rejects.toThrow("not_found")
  })
})

describe("moveVerdict", () => {
  it("leaves a loss unmeasured when a read behind it failed (run 45820934296's cut drill)", () => {
    expect(moveVerdict(["chat open nowhere", "draft"], ["summary on A: read ECONNRESET"])).toBe("unmeasured")
  })
  it("keeps a loss whose reads all answered", () => {
    expect(moveVerdict(["queued prompt ran 2 times"], [])).toBe("fail")
  })
  it("passes a run that lost nothing even if a side read failed", () => {
    expect(moveVerdict([], ["events on L: no answer"])).toBe("pass")
  })
})
