import { describe, expect, test } from "bun:test";
import { assertJournalPrefix, assertNoShellReplay, claudeLoginFromEnv, freezeOwned, validateProvenance, waitStore } from "./auto-journal-nightly-recovery.ts";

describe("auto journal nightly recovery boundary", () => {
  const good = { source_sha: "0123456789abcdef0123456789abcdef01234567", workflow_run: 123, artifact_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", published: true };
  test("pins a published artifact to a full source SHA and digest", () => {
    expect(validateProvenance(good).source_sha).toHaveLength(40);
    expect(() => validateProvenance({ ...good, source_sha: "main" })).toThrow("full 40-hex");
    expect(() => validateProvenance({ ...good, published: false })).toThrow("published");
    expect(() => validateProvenance({ ...good, workflow_run: " " })).toThrow("workflow_run");
    expect(() => validateProvenance({ ...good, workflow_run: 0 })).toThrow("workflow_run");
  });
  test("accepts native journal lines and rejects shell replay", () => {
    expect(() => assertJournalPrefix(["vm:vm_1 journal:epoch=2 prefix=auto"], "vm:vm_1")).not.toThrow();
    expect(() => assertJournalPrefix(["device:d journal"], "vm:vm_1")).toThrow("native holder prefix");
    expect(() => assertNoShellReplay(["vm:vm_1 journal:turn"])).not.toThrow();
    expect(() => assertNoShellReplay(["vm:vm_1 shell replay: bash -c x"])).toThrow("shell replay");
  });

  test("never freezes a caller-supplied process-shaped object", () => {
    expect(() => freezeOwned({ pid: process.pid, exitCode: null, spawnargs: ["not-owned"] })).toThrow("non-owned");
  });

  test("validates Claude setup-token shape without echoing the secret", () => {
    const token = `sk-ant-oat01-${"x".repeat(19)}`;
    expect(claudeLoginFromEnv({ CLAUDE_CODE_OAUTH_TOKEN: `  ${token}  ` })).toBe(token);
    expect(() => claudeLoginFromEnv({ CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-short" })).toThrow("setup-token");
  });

  test("rejects invalid store wait cursors before making a request", async () => {
    const api = { origin: "https://example.test", bearer: "bearer" };
    await expect(waitStore(api, "session", -1)).rejects.toThrow("non-negative integer");
    await expect(waitStore(api, "", 0)).rejects.toThrow("session id");
    await expect(waitStore(api, "session", 0, Number.NaN)).rejects.toThrow("finite");
  });
});
