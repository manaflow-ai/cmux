import { describe, expect, test } from "bun:test";
import { assertJournalPrefix, assertNoShellReplay, validateProvenance } from "./auto-journal-nightly-recovery.ts";

describe("auto journal nightly recovery boundary", () => {
  const good = { source_sha: "0123456789abcdef0123456789abcdef01234567", workflow_run: 123, artifact_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", published: true };
  test("pins a published artifact to a full source SHA and digest", () => {
    expect(validateProvenance(good).source_sha).toHaveLength(40);
    expect(() => validateProvenance({ ...good, source_sha: "main" })).toThrow("full 40-hex");
    expect(() => validateProvenance({ ...good, published: false })).toThrow("published");
  });
  test("accepts native journal lines and rejects shell replay", () => {
    expect(() => assertJournalPrefix(["vm:vm_1 journal:epoch=2 prefix=auto"], "vm:vm_1")).not.toThrow();
    expect(() => assertJournalPrefix(["device:d journal"], "vm:vm_1")).toThrow("native holder prefix");
    expect(() => assertNoShellReplay(["vm:vm_1 journal:turn"])).not.toThrow();
    expect(() => assertNoShellReplay(["vm:vm_1 shell replay: bash -c x"])).toThrow("shell replay");
  });
});
