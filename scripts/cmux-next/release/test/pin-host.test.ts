// pin-host.ts (cmux-vm production, 2026-10-09): the smoke must not depend on the runner's resolver. The first
// production deploy queried vm.cmux.dev before its record existed (ENOTFOUND), and the rerun's runner reached an
// AAAA address without an IPv6 route ("Unable to connect"). pin-host resolves through DoH, waits while there is
// no answer, prefers IPv4, and prints "<address> <host>" for /etc/hosts so TLS and SNI keep the real name.
import { describe, expect, it } from "bun:test"
import { pinAddress, type Resolve } from "../pin-host.ts"

const answers = (a: Array<string>, aaaa: Array<string>): Resolve => async (_host, type) => (type === "A" ? a : aaaa)

describe("pinAddress", () => {
  it("prefers IPv4 even when IPv6 answers exist and the runner has an IPv6 route", async () => {
    const r = await pinAddress({ host: "vm.cmux.dev", resolve: answers(["104.21.25.36", "172.67.222.87"], ["2606:4700:3037::6815:1924"]), ipv6Route: true, waitMs: 1000, intervalMs: 1 })
    expect(r).toBe("104.21.25.36")
  })

  it("waits while the resolver has no answer or fails, then pins the first IPv4", async () => {
    let n = 0
    const resolve: Resolve = async (_host, type) => {
      n++
      if (n === 1) throw new Error("doh down")
      if (n <= 4) return []
      return type === "A" ? ["172.67.222.87"] : []
    }
    expect(await pinAddress({ host: "vm.cmux.dev", resolve, ipv6Route: false, waitMs: 1000, intervalMs: 1 })).toBe("172.67.222.87")
  })

  it("uses IPv6 only when there is no IPv4 answer and the runner has an IPv6 route", async () => {
    expect(await pinAddress({ host: "h.cmux.dev", resolve: answers([], ["2606:4700::1"]), ipv6Route: true, waitMs: 1000, intervalMs: 1 })).toBe("2606:4700::1")
    await expect(pinAddress({ host: "h.cmux.dev", resolve: answers([], ["2606:4700::1"]), ipv6Route: false, waitMs: 20, intervalMs: 1 })).rejects.toThrow(
      "h.cmux.dev has no usable address within",
    )
  })

  it("fails after the bound with the host in the message", async () => {
    await expect(pinAddress({ host: "vm.cmux.dev", resolve: answers([], []), ipv6Route: true, waitMs: 20, intervalMs: 1 })).rejects.toThrow(
      "vm.cmux.dev has no usable address within",
    )
  })

  it("refuses a host that is not a DNS name, and ignores answers that are not addresses", async () => {
    await expect(pinAddress({ host: "vm.cmux.dev;rm -rf /", resolve: answers(["1.2.3.4"], []), ipv6Route: false, waitMs: 20, intervalMs: 1 })).rejects.toThrow("not a host name")
    expect(await pinAddress({ host: "vm.cmux.dev", resolve: answers(["cname.example.", "104.21.25.36"], []), ipv6Route: false, waitMs: 1000, intervalMs: 1 })).toBe("104.21.25.36")
  })
})
