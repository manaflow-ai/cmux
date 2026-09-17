import { expect, test } from "bun:test";
import { diffWorkerPoolSizeForUserAgent } from "../src/worker-pool";

test("diff worker pool uses the desktop cap by default", () => {
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe(3);
  expect(diffWorkerPoolSizeForUserAgent(undefined)).toBe(3);
});

test("diff worker pool uses the mobile cap for phone and tablet user agents", () => {
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)")).toBe(1);
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X)")).toBe(1);
  expect(diffWorkerPoolSizeForUserAgent("Mozilla/5.0 (Linux; Android 15; Pixel 9) Mobile")).toBe(1);
});
