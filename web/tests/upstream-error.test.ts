import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { hasStatus, isAccountLimit, isCapacity, retryAfterSeconds } from "../services/upstreamError";

// The same rows the Rust crate's matrix test reads (cmux-upstream-error/cases.tsv), so the
// TypeScript port and the crate classify every string alike (ask-616b73f6bc).
const rows = readFileSync(
  new URL("../../cmux-tui/crates/cmux-upstream-error/cases.tsv", import.meta.url),
  "utf8",
)
  .split("\n")
  .filter((line) => line !== "" && !line.startsWith("#"))
  .map((line) => line.split("\t"));

test("the shared matrix: capacity, account limit and retry-after, as the crate reads them", () => {
  expect(rows).toHaveLength(12);
  for (const [message, capacity, limit, wait] of rows) {
    expect({ message, isCapacity: isCapacity(message), isAccountLimit: isAccountLimit(message), retryAfter: retryAfterSeconds(message) }).toEqual({
      message,
      isCapacity: capacity === "true",
      isAccountLimit: limit === "true",
      retryAfter: wait === "-" ? undefined : Number(wait),
    });
  }
});

test("a status is a number of its own", () => {
  expect(hasStatus("http 503 unavailable", "503")).toBe(true);
  expect(hasStatus("took 2503s", "503")).toBe(false);
  expect(hasStatus("id 5290", "529")).toBe(false);
  // As the crate: an underscore is not alphanumeric, so "status_529" names 529.
  expect(hasStatus("status_529", "529")).toBe(true);
});

test("retry-after reads the JSON string form", () => {
  expect(retryAfterSeconds('{"retry-after":"30"}')).toBe(30);
  expect(retryAfterSeconds("Retry-After: 7")).toBe(7);
  expect(retryAfterSeconds("retry after soon")).toBeUndefined();
});
