import { describe, expect, test } from "bun:test";
import { VM_FORK_METHOD_METADATA_KEY, readVmForkMethod } from "../services/vms/forkMethod";

describe("persisted fork method", () => {
  test("round-trips the two known copy methods", () => {
    expect(readVmForkMethod({ [VM_FORK_METHOD_METADATA_KEY]: "native-live" })).toBe("native-live");
    expect(readVmForkMethod({ [VM_FORK_METHOD_METADATA_KEY]: "snapshot-create" })).toBe("snapshot-create");
  });

  test("legacy and malformed metadata stay unknown", () => {
    expect(readVmForkMethod(null)).toBe("unknown");
    expect(readVmForkMethod({})).toBe("unknown");
    expect(readVmForkMethod({ [VM_FORK_METHOD_METADATA_KEY]: "unknown" })).toBe("unknown");
    expect(readVmForkMethod({ [VM_FORK_METHOD_METADATA_KEY]: true })).toBe("unknown");
    expect(readVmForkMethod({ [VM_FORK_METHOD_METADATA_KEY]: "native" })).toBe("unknown");
  });
});
