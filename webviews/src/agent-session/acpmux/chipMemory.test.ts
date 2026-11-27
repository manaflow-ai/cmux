import { expect, test } from "bun:test";
import { shouldUseLastChips } from "./chipMemory";

test("keeps the cached effort through a fresh session attach gap", () => {
  expect(
    shouldUseLastChips({
      chipHarness: "claude",
      opensListed: false,
      awaiting: false,
      fresh: true,
      effortKnown: false,
    }),
  ).toBe(true);
});

test("stops using the cache once the fresh session reports effort", () => {
  expect(
    shouldUseLastChips({
      chipHarness: "claude",
      opensListed: false,
      awaiting: false,
      fresh: true,
      effortKnown: true,
    }),
  ).toBe(false);
});

test("does not borrow another chat's effort for an already opened chat", () => {
  expect(
    shouldUseLastChips({
      chipHarness: "claude",
      opensListed: true,
      awaiting: true,
      fresh: false,
      effortKnown: false,
    }),
  ).toBe(false);
});
