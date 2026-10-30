/**
 * Pins a smoke host's address so a smoke never depends on the runner's resolver
 * (cmux-vm production, 2026-10-09: the first deploy's smoke queried vm.cmux.dev before
 * its record existed, ENOTFOUND; the rerun's runner reached an AAAA address with no
 * IPv6 route, "Unable to connect").
 *
 *   bun pin-host.ts --host vm.cmux.dev [--wait-seconds 300] [--interval-ms 5000]
 *
 * Resolves A and AAAA through DoH (cloudflare-dns.com), waits while there is no
 * answer (an empty answer or a resolver error is "not yet"), prefers IPv4, and uses
 * IPv6 only when there is no A answer and the runner has an IPv6 default route.
 * Prints one /etc/hosts line, "<address> <host>"; the workflow appends it, so TLS
 * and SNI keep the real name. Exit 1 when no usable address appears in time.
 */
import { spawnSync } from "node:child_process"
import { isIPv4, isIPv6 } from "node:net"

export type Resolve = (host: string, type: "A" | "AAAA") => Promise<ReadonlyArray<string>>

const HOST = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i

/** DoH JSON API: the answers of `type` (A = 1, AAAA = 28); NXDOMAIN or no answer is an empty list. */
export const dohResolve: Resolve = async (host, type) => {
  const url = new URL("https://cloudflare-dns.com/dns-query")
  url.searchParams.set("name", host)
  url.searchParams.set("type", type)
  const response = await fetch(url, { headers: { accept: "application/dns-json" }, signal: AbortSignal.timeout(10_000) })
  if (!response.ok) throw new Error(`DoH ${response.status}`)
  const body = (await response.json()) as { Status?: number; Answer?: Array<{ type?: number; data?: string }> }
  if (body.Status !== 0) return []
  const want = type === "A" ? 1 : 28
  return (body.Answer ?? []).filter((a) => a.type === want && typeof a.data === "string").map((a) => a.data as string)
}

export interface PinOptions {
  readonly host: string
  readonly resolve: Resolve
  /** Whether the runner can reach IPv6 at all (an IPv6 default route). */
  readonly ipv6Route: boolean
  readonly waitMs: number
  readonly intervalMs: number
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

const answersOf = async (resolve: Resolve, host: string, type: "A" | "AAAA"): Promise<ReadonlyArray<string>> => {
  try {
    return await resolve(host, type)
  } catch {
    return []
  }
}

/** The address to pin for `host`: the first IPv4 answer, else (with an IPv6 route) the first IPv6 answer. */
export const pinAddress = async (o: PinOptions): Promise<string> => {
  if (!HOST.test(o.host)) throw new Error(`${JSON.stringify(o.host)} is not a host name`)
  const deadline = Date.now() + o.waitMs
  for (;;) {
    const v4 = (await answersOf(o.resolve, o.host, "A")).find((a) => isIPv4(a))
    if (v4) return v4
    if (o.ipv6Route) {
      const v6 = (await answersOf(o.resolve, o.host, "AAAA")).find((a) => isIPv6(a))
      if (v6) return v6
    }
    if (Date.now() >= deadline) throw new Error(`${o.host} has no usable address within ${Math.round(o.waitMs / 1000)} s (IPv6 route: ${o.ipv6Route ? "yes" : "no"})`)
    await sleep(o.intervalMs)
  }
}

const hasIpv6Route = (): boolean => {
  const run = spawnSync("ip", ["-6", "route", "show", "default"], { encoding: "utf8" })
  return run.status === 0 && run.stdout.trim() !== ""
}

if (import.meta.main) {
  const argv = process.argv.slice(2)
  const value = (flag: string) => (argv.includes(flag) ? argv[argv.indexOf(flag) + 1] : undefined)
  const host = value("--host") ?? ""
  const ipv6Route = hasIpv6Route()
  try {
    const address = await pinAddress({
      host,
      resolve: dohResolve,
      ipv6Route,
      waitMs: Number(value("--wait-seconds") ?? 300) * 1000,
      intervalMs: Number(value("--interval-ms") ?? 5000),
    })
    console.error(`pin-host: ${host} -> ${address} (DoH; IPv6 route: ${ipv6Route ? "yes" : "no"})`)
    console.log(`${address} ${host}`)
  } catch (e) {
    console.error(`pin-host: ${(e as Error).message}`)
    process.exit(1)
  }
}
