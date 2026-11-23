import { expect, test } from "bun:test";
import { diskHealthState } from "./model";
import type { CloudDiskHealth } from "./ops";

const report = (patch: Partial<CloudDiskHealth> = {}): CloudDiskHealth => ({
  state: "healthy",
  free_mb: 8_192,
  used_mb: 57_344,
  total_mb: 65_536,
  floor_mb: 4_096,
  top_users: [],
  observed_at: 1_000_000,
  ...patch,
});

test("disk health warns at the configured floor", () => {
  expect(diskHealthState(report({ free_mb: 4_096, state: "warning" }), 1_000_000)).toBe("warning");
  expect(diskHealthState(report({ free_mb: 4_097 }), 1_000_000)).toBe("healthy");
});

test("disk health becomes stale after fifteen minutes", () => {
  expect(diskHealthState(report(), 1_000_000 + 15 * 60_000)).toBe("healthy");
  expect(diskHealthState(report(), 1_000_000 + 15 * 60_000 + 1)).toBe("stale");
});

test("missing and inconsistent reports are not actionable", () => {
  expect(diskHealthState(undefined, 1_000_000)).toBe("unknown");
  expect(diskHealthState(report({ used_mb: 70_000, state: "unknown" }), 1_000_000)).toBe("unknown");
  expect(diskHealthState(report({ free_mb: 60_000, used_mb: 10_000, state: "unknown" }), 1_000_000)).toBe("unknown");
  expect(diskHealthState(report({ observed_at: Number.NaN }), 1_000_000)).toBe("unknown");
  expect(diskHealthState(report({ observed_at: 2_000_000 }), 1_000_000)).toBe("unknown");
  expect(
    diskHealthState(
      report({
        state: "unknown",
        top_users: [
          { path: "", used_mb: 1 },
          { path: "/tmp", used_mb: Number.NaN },
        ],
      }),
      1_000_000,
    ),
  ).toBe("unknown");
});
