import { describe, expect, test } from "bun:test";
import { readAutoSizeWarning } from "./autoSizeWarningModel";

describe("readAutoSizeWarning", () => {
  test("reads the camel-cased Rust warning payload", () => {
    expect(
      readAutoSizeWarning({
        command: "cargo build --release",
        short: ["disk", "memory"],
        needsDisk: 40,
        needsMemory: 3,
        text: "too large",
      }),
    ).toEqual({
      command: "cargo build --release",
      short: ["disk", "memory"],
      needsDisk: 40,
      needsMemory: 3,
      text: "too large",
    });
  });

  test("rejects unknown enum values and invalid required fields", () => {
    expect(readAutoSizeWarning({ command: "cargo", short: ["cpu"], text: "too large" })).toBeUndefined();
    expect(readAutoSizeWarning({ command: "cargo", short: [], text: "" })).toBeUndefined();
    expect(readAutoSizeWarning({ command: "cargo", short: [], text: "too large", needsMemory: 0 })).toBeUndefined();
  });
});
