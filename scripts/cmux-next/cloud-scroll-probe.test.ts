// The Cloud surface of the terminal scroll-integrity probe (cloud-scroll-probe.ts). No network and no secret: a fake
// `cmux` plays `carrier serve` (its ready line) and `__scroll-probe` (its JSON report).
import { describe, expect, it } from "bun:test"
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { runCloudScrollProbe, scrollProbeDetail, scrollProbeFacts } from "./cloud-scroll-probe.ts"

const report = (mirror: number[], daemon: number[]) => JSON.stringify({
  surface: "cloud",
  bad: [...mirror, ...daemon].reduce((a, b) => a + b, 0),
  views: {
    mirror: { blank_rows: mirror[0], missing_rows: mirror[1], jumps: mirror[2], bad: mirror[0] + mirror[1] + mirror[2] },
    daemon: { blank_rows: daemon[0], missing_rows: daemon[1], jumps: daemon[2], bad: daemon[0] + daemon[1] + daemon[2] },
  },
  stream: { pruned: false },
  seconds: 41.27,
})

/** A fake cmux: `carrier serve` writes SERVE_LINE to stderr and stays up; `__scroll-probe` prints REPORT, exits CODE. */
const fakeCmux = (serveLine: string, probeOut: string, probeCode = 0) => {
  const dir = mkdtempSync(join(tmpdir(), "scroll-probe-test-"))
  const bin = join(dir, "cmux")
  writeFileSync(join(dir, "report.json"), `${probeOut}\n`)
  writeFileSync(bin, `#!/bin/sh
case "$1" in
  carrier) echo '${serveLine}' >&2; exec sleep 30 ;;
  __scroll-probe) cat "${dir}/report.json"; echo "probe args: $*" >&2; exit ${probeCode} ;;
esac
exit 64
`)
  chmodSync(bin, 0o755)
  return bin
}
const api = { origin: "https://api.invalid", bearer: "tok", team: null }

describe("scrollProbeFacts", () => {
  it("keeps the counts of both views and their sum", () => {
    const f = scrollProbeFacts(`noise\n${report([0, 0, 1], [2, 0, 0])}\n`)
    expect(f).toEqual({ bad: 3, mirror: { blank_rows: 0, missing_rows: 0, jumps: 1 }, daemon: { blank_rows: 2, missing_rows: 0, jumps: 0 }, seconds: 41.3, pruned: false })
    expect(scrollProbeDetail(f as any)).toBe("bad 3 (mirror 0 blank, 0 missing, 1 jumps; daemon 2 blank, 0 missing, 0 jumps) in 41.3 s")
  })
  it("refuses a report that is not one", () => {
    expect(scrollProbeFacts("")).toBe("the probe printed no report")
    expect(scrollProbeFacts("oops")).toStartWith("not a JSON report")
    expect(scrollProbeFacts(JSON.stringify({ bad: 0, views: { mirror: {} } }))).toBe("the report has no counts for both views")
  })
})

describe("runCloudScrollProbe", () => {
  it("serves the carrier, then probes its socket", async () => {
    const tracked: number[] = []
    const r = await runCloudScrollProbe(fakeCmux('{"ok":true,"route":"carrier"}', report([0, 0, 0], [0, 0, 0])), api, "vm_abc", (c) => tracked.push(c.pid ?? -1), 5)
    expect(r).toEqual({ facts: expect.objectContaining({ bad: 0 }) })
    expect(tracked.length).toBe(2)
  })
  it("answers why when carrier serve refuses", async () => {
    const r = await runCloudScrollProbe(fakeCmux('{"ok":false,"error_code":"no_device_key"}', ""), api, "vm_abc", undefined, 5)
    expect(r).toEqual({ why: 'carrier serve: {"ok":false,"error_code":"no_device_key"}' })
  })
  it("answers why when the probe fails", async () => {
    const r = await runCloudScrollProbe(fakeCmux('{"ok":true}', "", 1), api, "vm_abc", undefined, 5)
    expect("why" in r && r.why).toStartWith("__scroll-probe exit 1: probe args: __scroll-probe --socket ")
  })
})
