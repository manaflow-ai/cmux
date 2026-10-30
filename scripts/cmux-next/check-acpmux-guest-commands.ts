#!/usr/bin/env bun
/**
 * cx-kvmz: the keyed acpmux start has two copies of its fixed guest commands, the web one
 * (web/services/vms/drivers/acpmuxPersonKey.ts, cx-psxg slice 2d) and the API Worker one
 * (backend/apps/api/src/cloud-acpmux-guest.ts, slice 2e). This check builds every command and
 * frame from both copies and compares them byte for byte. Exit 0 when all match, 1 otherwise.
 *
 *   bun scripts/cmux-next/check-acpmux-guest-commands.ts
 */
import * as worker from "../../backend/apps/api/src/cloud-acpmux-guest.ts"
import * as web from "../../web/services/vms/drivers/acpmuxPersonKey.ts"

const nonce = "0123456789abcdef".repeat(4)
const pairs: Array<[string, unknown, unknown]> = [
  ["prepare command", web.acpmuxPrepareCommand(), worker.acpmuxPrepareCommand()],
  ["keyed start command", web.acpmuxKeyedStartCommand(), worker.acpmuxKeyedStartCommand()],
  ["person_holds command", web.acpmuxPersonHoldsCommand(), worker.acpmuxPersonHoldsCommand()],
  ["person_holds frames", web.acpmuxPersonHoldsFrames(nonce), worker.acpmuxPersonHoldsFrames(nonce)],
  ["team machine exit", web.ACPMUX_EXIT_TEAM_VM, worker.ACPMUX_EXIT_TEAM_VM],
  ["unsupported exit", web.ACPMUX_EXIT_UNSUPPORTED, worker.ACPMUX_EXIT_UNSUPPORTED],
  ["stdin exec timeout", web.ACPMUX_STDIN_EXEC_TIMEOUT_MS, worker.ACPMUX_STDIN_EXEC_TIMEOUT_MS],
  ["prepare timeout", web.ACPMUX_PREPARE_TIMEOUT_MS, worker.ACPMUX_PREPARE_TIMEOUT_MS]
]

const lines = [`${"0123456789abcdef".repeat(4)}\n`, `${"0123456789ABCDEF".repeat(4)}\n`, `${"0".repeat(64)}`, `${"g".repeat(64)}\n`, `${"0".repeat(65)}\n`]
for (const line of lines) {
  const bytes = new TextEncoder().encode(line)
  pairs.push([`key line check ${JSON.stringify(line.slice(0, 6))}... (${bytes.byteLength} bytes)`, web.isAcpmuxKeyLine(bytes), worker.isAcpmuxKeyLine(bytes)])
}
for (const text of ["", "one\ntwo  \n", `cmux: ${"ab".repeat(40)} and ${"A".repeat(90)}==`]) pairs.push([`guest line redaction ${JSON.stringify(text.slice(0, 8))}`, web.redactGuestLine(text), worker.redactGuestLine(text)])
for (const n of [nonce, nonce.toUpperCase(), "zz", 7]) pairs.push([`nonce check ${JSON.stringify(n).slice(0, 10)}`, web.isAcpmuxNonce(n), worker.isAcpmuxNonce(n)])

let failed = 0
for (const [name, a, b] of pairs) {
  const same = typeof a === "string" && typeof b === "string" ? Buffer.from(a, "utf8").equals(Buffer.from(b, "utf8")) : a === b
  if (!same) {
    failed++
    console.error(`DIFFERENT ${name}`)
    if (typeof a === "string" && typeof b === "string") {
      let i = 0
      while (i < a.length && a[i] === b[i]) i++
      console.error(`  first difference at byte ${i}: web ${JSON.stringify(a.slice(i, i + 60))} worker ${JSON.stringify(b.slice(i, i + 60))}`)
    } else console.error(`  web ${JSON.stringify(a)} worker ${JSON.stringify(b)}`)
  } else console.log(`same ${name}${typeof a === "string" ? ` (${Buffer.byteLength(a)} bytes)` : ""}`)
}
if (failed) {
  console.error(`${failed} of ${pairs.length} differ: change web/services/vms/drivers/acpmuxPersonKey.ts and backend/apps/api/src/cloud-acpmux-guest.ts together`)
  process.exit(1)
}
console.log(`all ${pairs.length} match byte for byte`)
