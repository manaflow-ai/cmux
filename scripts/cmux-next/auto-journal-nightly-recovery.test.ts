import { describe, expect, test } from "bun:test";
import { claudeLoginFromEnv, countNonce, equalEventTuples, eventTuples, freezeOwned, validateProvenance, waitStore } from "./auto-journal-nightly-recovery.ts";
describe("auto journal nightly recovery", () => {
  const good = { source_sha: "0123456789abcdef0123456789abcdef01234567", workflow_run: 123, artifact_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", published: true };
  test("pins a published artifact", () => { expect(validateProvenance(good).source_sha).toHaveLength(40); expect(() => validateProvenance({ ...good, source_sha: "main" })).toThrow("full 40-hex"); });
  test("compares native event tuples exactly", () => { const a = eventTuples([{ seq: 1, record: { kind: "user", msg: "x" } }]); expect(equalEventTuples(a, [...a])).toBe(true); expect(equalEventTuples(a, [{ seq: 1, kind: "user", msg: "y" }])).toBe(false); });
  test("counts one nonce execution", () => { expect(countNonce([{ text: "rfd0080-n" }, { text: "other" }], "rfd0080-n")).toBe(1); });
  test("does not freeze an arbitrary process", () => { expect(() => freezeOwned({ pid: process.pid, exitCode: null } as any)).toThrow("non-owned"); });
  test("validates Claude setup token without echoing it", () => { const t = `sk-ant-oat01-${"x".repeat(19)}`; expect(claudeLoginFromEnv({ CLAUDE_CODE_OAUTH_TOKEN: ` ${t} ` })).toBe(t); });
  test("rejects invalid store cursor", async () => { const api = { origin: "https://example.test", bearer: "bearer" }; await expect(waitStore(api, "session", -1)).rejects.toThrow("non-negative integer"); });
});
