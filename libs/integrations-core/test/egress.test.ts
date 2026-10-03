import { describe, expect, test } from "bun:test"
import { CATALOG_BLOB_MAX_BYTES, checkDocumentSize, checkEgressUrl, checkGenericTarget, EGRESS_LIMITS, hostAllowed, isPrivateHost, isValidHostPattern, parseHttpUrl } from "../src/egress.ts"
import { utf8Length } from "../src/text.ts"

describe("URL parsing", () => {
  test("http(s) only, with host, port and userinfo", () => {
    expect(parseHttpUrl("https://API.Example.com:8443/openapi.json?x=1")).toEqual({ scheme: "https", host: "api.example.com", port: 8443, userinfo: false })
    expect(parseHttpUrl("http://[::1]:80/")).toEqual({ scheme: "http", host: "::1", port: 80, userinfo: false })
    expect(parseHttpUrl("https://user:pw@example.com/")?.userinfo).toBe(true)
    expect(parseHttpUrl("ftp://example.com")).toBeNull()
    expect(parseHttpUrl("file:///etc/passwd")).toBeNull()
    expect(parseHttpUrl("https://exa mple.com")).toBeNull()
    expect(parseHttpUrl("https://example.com:99999/")).toBeNull()
    expect(parseHttpUrl("https://ex%61mple.com/")).toBeNull()
  })
})

describe("private targets", () => {
  test("loopback, private, link-local, shared and unspecified IPv4 in every literal form", () => {
    for (const h of ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.100.1.1", "0.0.0.0", "2130706433", "0x7f.1", "0177.0.0.1", "127.1", "224.0.0.1"]) expect(`${h}:${isPrivateHost(h)}`).toBe(`${h}:true`)
    for (const h of ["8.8.8.8", "172.32.0.1", "100.128.0.1", "1.1.1.1", "93.184.216.34"]) expect(`${h}:${isPrivateHost(h)}`).toBe(`${h}:false`)
  })

  test("loopback, link-local, ULA and IPv4-embedding IPv6", () => {
    for (const h of ["::1", "::", "fe80::1", "fe80::1%25en0", "fd12:3456::1", "fc00::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "64:ff9b::10.0.0.1", "2002:c0a8:0101::1", "ff02::1"]) expect(`${h}:${isPrivateHost(h)}`).toBe(`${h}:true`)
    for (const h of ["2606:4700:4700::1111", "::ffff:8.8.8.8", "2001:db8::1".replace("db8", "4860")]) expect(`${h}:${isPrivateHost(h)}`).toBe(`${h}:false`)
  })

  test("local names and single labels", () => {
    for (const h of ["localhost", "api.localhost", "printer.local", "db.internal", "nas.home.arpa", "intranet", "localhost."]) expect(`${h}:${isPrivateHost(h)}`).toBe(`${h}:true`)
    expect(isPrivateHost("api.example.com")).toBe(false)
  })

  test("checkEgressUrl returns the gateway's error codes", () => {
    expect(checkEgressUrl("https://api.example.com/openapi.json")).toEqual({ ok: true, host: "api.example.com" })
    expect(checkEgressUrl("http://169.254.169.254/latest/meta-data")).toEqual({ ok: false, code: "egress.private_target", host: "169.254.169.254" })
    expect(checkEgressUrl("https://[fd00::1]/spec")).toMatchObject({ ok: false, code: "egress.private_target" })
    expect(checkEgressUrl("https://user:secret@api.example.com/")).toMatchObject({ ok: false, code: "egress.credentials_in_url" })
    expect(checkEgressUrl("gopher://api.example.com/")).toEqual({ ok: false, code: "egress.invalid_url" })
  })
})

describe("limits", () => {
  test("10 MB documents, 30 s, 2 MB catalogs", () => {
    expect(EGRESS_LIMITS).toEqual({ maxResponseBytes: 10_485_760, timeoutMs: 30_000 })
    expect(CATALOG_BLOB_MAX_BYTES).toBe(2_097_152)
    expect(checkDocumentSize("x".repeat(10))).toBeNull()
    expect(checkDocumentSize("x".repeat(EGRESS_LIMITS.maxResponseBytes + 1))).toEqual({ ok: false, code: "egress.too_large" })
  })

  test("utf8Length matches TextEncoder", () => {
    for (const s of ["", "abc", "é", "連携", "😀", "a\ud800b"]) expect(utf8Length(s)).toBe(new TextEncoder().encode(s).length)
  })
})

describe("team host allowlist (generic_hosts)", () => {
  test("null allows any public host; a list allows exact hosts and subdomains", () => {
    expect(hostAllowed("api.example.com", null)).toBe(true)
    expect(hostAllowed("api.example.com", ["api.example.com"])).toBe(true)
    expect(hostAllowed("v2.api.example.com", ["*.example.com"])).toBe(true)
    expect(hostAllowed("example.com", ["*.example.com"])).toBe(false)
    expect(hostAllowed("evil-example.com", ["*.example.com"])).toBe(false)
    expect(hostAllowed("api.example.com", [])).toBe(false)
  })

  test("pattern validation", () => {
    expect(["api.example.com", "*.example.com", "localhost-free.dev"].every(isValidHostPattern)).toBe(true)
    expect(["*", "*.com", "a.*.com", "", "https://x.com"].some(isValidHostPattern)).toBe(false)
  })

  test("checkGenericTarget refuses private targets before the allowlist", () => {
    expect(checkGenericTarget("https://127.0.0.1/", ["127.0.0.1"])).toMatchObject({ code: "egress.private_target" })
    expect(checkGenericTarget("https://api.other.com/", ["*.example.com"])).toEqual({ ok: false, code: "egress.host_not_allowed", host: "api.other.com" })
    expect(checkGenericTarget("https://api.example.com/", ["*.example.com"])).toEqual({ ok: true, host: "api.example.com" })
  })
})
