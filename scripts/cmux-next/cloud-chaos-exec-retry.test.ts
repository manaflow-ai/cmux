// Run 46116359583, session host restart: the counting-files write met one 502 vm_unavailable (the provider's exec
// failed on a running machine) and the leg failed at 0 ms without trying again.
import { describe, expect, it } from "bun:test"
import { idempotentExec } from "./cloud-chaos.ts"

const refused = { code: 1, stdout: "", stderr: '{"code":"cloud_client_session.failed","message":"the cmux API refused the command: 502 Bad Gateway vm_unavailable","retryable":false}' }

describe("idempotentExec", () => {
  it("retries a refused exec and returns the good answer", async () => {
    let n = 0
    const r = await idempotentExec(async () => (n++ === 0 ? refused : { code: 0, stdout: "@@dir /x", stderr: "" }), "c", 1_000, 1_000, 1)
    expect(r.stdout).toBe("@@dir /x")
    expect(r.tries).toBe(2)
  })

  it("a thrown 503 is retried too", async () => {
    let n = 0
    const r = await idempotentExec(async () => {
      if (n++ === 0) throw new Error("exec: HTTP 503 Service Unavailable vm_unavailable")
      return { code: 0, stdout: "ok", stderr: "" }
    }, "c", 1_000, 1_000, 1)
    expect(r.code).toBe(0)
  })

  it("the command's own failure comes back at once", async () => {
    let n = 0
    const r = await idempotentExec(async () => { n++; return { code: 1, stdout: "", stderr: "mkdir: Permission denied" } }, "c", 1_000, 1_000, 1)
    expect(n).toBe(1)
    expect(r.tries).toBe(1)
  })

  it("stops at its budget and names the last refusal", async () => {
    const r = await idempotentExec(async () => refused, "c", 1_000, 20, 1)
    expect(r.stderr).toContain("vm_unavailable")
    expect(r.tries).toBeGreaterThan(1)
  })
})
