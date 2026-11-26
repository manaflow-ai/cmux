import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { reachabilityKey } from "../scripts/check-devbox-image-reachable";

describe("devbox reachability run key", () => {
  const defaults = [
    { version: "base-sm", imageId: "sh-aaa" },
    { version: "base-md", imageId: "sh-bbb" },
  ];

  test("the same images and client repeat a key, so CI can skip the run", () => {
    expect(reachabilityKey(defaults, "client-1")).toBe(reachabilityKey(defaults, "client-1"));
  });

  test("order of the defaults does not change the key", () => {
    expect(reachabilityKey([...defaults].reverse(), "client-1")).toBe(reachabilityKey(defaults, "client-1"));
  });

  test("a promoted image is a new pair to test", () => {
    const promoted = [{ version: "base-sm", imageId: "sh-ccc" }, defaults[1]!];
    expect(reachabilityKey(promoted, "client-1")).not.toBe(reachabilityKey(defaults, "client-1"));
  });

  test("a new cmux-tui release is a new pair to test", () => {
    // This is the case with no commit behind it: files.cmux.com moves and the
    // manifest does not, which is exactly what the daily run is for.
    expect(reachabilityKey(defaults, "client-2")).not.toBe(reachabilityKey(defaults, "client-1"));
  });
});


test("reachability cache includes the probe implementation and runs when it changes", () => {
  const workflow = readFileSync(new URL("../../.github/workflows/cloud-vm-image-reachability.yml", import.meta.url), "utf8");
  const key = workflow.split("\n").find((line) => line.trim().startsWith("key: devbox-reachable-"))!;
  expect(key).toContain("hashFiles(");
  for (const file of ["web/scripts/check-devbox-image-reachable.ts", "web/scripts/devbox-image-common.ts", "web/services/vms/drivers/cmuxTuiDaemon.ts"]) {
    expect(key).toContain(file);
    // Every probe dependency must trigger both a pull-request and main check.
    expect(workflow.split("  push:")[1]!.split("  schedule:")[0]).toContain(`- ${file}`);
  }
});
