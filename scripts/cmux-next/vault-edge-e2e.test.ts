import { describe, expect, test } from "bun:test"
import { spawnSync } from "node:child_process"
import { randomBytes } from "node:crypto"
import {
  carriers, echoCommand, OTHER_ECHO, parseCli, PINNED_ECHO, redact, scanPasses, scanReadCommand, scanStartCommand, sha256,
} from "./vault-edge-e2e"

const parses = (script: string) => spawnSync("sh", ["-n"], { input: script }).status

describe("vault-edge-e2e harness", () => {
  test("every command the VM runs parses and carries no value", () => {
    const value = randomBytes(32).toString("hex")
    for (const cmd of [scanStartCommand(), scanReadCommand(), echoCommand(PINNED_ECHO), echoCommand(OTHER_ECHO)]) {
      expect(parses(cmd)).toBe(0)
      expect(cmd).not.toContain(value)
      expect(cmd).not.toContain(value.slice(0, 16))
    }
  })

  test("carriers names only the headers whose hash matches", () => {
    const want = sha256("v")
    expect(carriers({ status: 200, headers: { "x-vault-edge-e2e": want, host: sha256("h") } }, want)).toEqual(["x-vault-edge-e2e"])
    expect(carriers({ status: 200, headers: { host: sha256("h") } }, want)).toEqual([])
  })

  test("scanPasses needs a clean, finished scan that saw processes", () => {
    const ok = { uid: 0, files_rc: 1, unread: 0, file_hits: [], proc_hits: [], procs: 90, acpmux_dirs: [] }
    expect(scanPasses(ok)).toBe(true)
    expect(scanPasses({ ...ok, file_hits: ["/etc/x"] })).toBe(false)
    expect(scanPasses({ ...ok, proc_hits: ["/proc/1/environ"] })).toBe(false)
    expect(scanPasses({ ...ok, procs: 0 })).toBe(false)
    expect(scanPasses({ ...ok, files_rc: 2 })).toBe(false)
    expect(scanPasses({ ...ok, files_rc: 123 })).toBe(true)
    expect(scanPasses({ ...ok, files_rc: 123, unread: 3 })).toBe(false)
    expect(scanPasses({ ...ok, uid: 1000 })).toBe(false)
  })

  test("redact hides every secret of 8+ characters", () => {
    expect(redact("a tok-12345678 b tok-12345678", ["tok-12345678", "x"])).toBe("a [secret] b [secret]")
  })

  test("parseCli checks the backend and run id", () => {
    expect(parseCli(["--backend", "staging", "--out", "/tmp/o", "--run-id", "r1"])).toEqual({ backend: "staging", out: "/tmp/o", runId: "r1" })
    expect(() => parseCli(["--backend", "prod", "--out", "/tmp/o"])).toThrow()
    expect(() => parseCli(["--backend", "dev"])).toThrow()
    expect(() => parseCli(["--out", "/tmp/o", "--run-id", "Bad Id"])).toThrow()
  })
})
