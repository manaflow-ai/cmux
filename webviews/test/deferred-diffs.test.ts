import { expect, test } from "bun:test";
import {
  deferredDiffReason,
  isWellKnownLockfile,
  LARGE_DIFF_CHANGED_LINES,
  LARGE_DIFF_PATCH_BYTES,
} from "../src/deferred-diffs";

test("well-known lockfiles are recognized by basename in any directory", () => {
  for (const name of [
    "bun.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "Cargo.lock",
    "Package.resolved",
    "go.sum",
    "Gemfile.lock",
    "poetry.lock",
    "uv.lock",
  ]) {
    expect(isWellKnownLockfile(name)).toBe(true);
    expect(isWellKnownLockfile(`packages/web/${name}`)).toBe(true);
  }
  expect(isWellKnownLockfile("src/lock.ts")).toBe(false);
  expect(isWellKnownLockfile("Package.swift")).toBe(false);
});

test("deferredDiffReason marks generated files first, then large diffs", () => {
  const generated = new Set(["dist/bundle.js"]);
  expect(
    deferredDiffReason({ path: "src/app.ts", changedLines: 10, patchBytes: 100, generatedPaths: generated }),
  ).toBeUndefined();
  expect(
    deferredDiffReason({ path: "dist/bundle.js", changedLines: 10, patchBytes: 100, generatedPaths: generated }),
  ).toBe("generated");
  expect(deferredDiffReason({ path: "bun.lock", changedLines: 10, patchBytes: 100, generatedPaths: generated })).toBe(
    "generated",
  );
  expect(
    deferredDiffReason({
      path: "src/big.ts",
      changedLines: LARGE_DIFF_CHANGED_LINES,
      patchBytes: 100,
      generatedPaths: generated,
    }),
  ).toBe("large");
  expect(
    deferredDiffReason({
      path: "src/big.ts",
      changedLines: LARGE_DIFF_CHANGED_LINES - 1,
      patchBytes: 100,
      generatedPaths: generated,
    }),
  ).toBeUndefined();
  expect(
    deferredDiffReason({
      path: "src/wide.ts",
      changedLines: 1,
      patchBytes: LARGE_DIFF_PATCH_BYTES,
      generatedPaths: generated,
    }),
  ).toBe("large");
  // Generated wins over large so the badge explains why the file is collapsed.
  expect(
    deferredDiffReason({ path: "yarn.lock", changedLines: 99_999, patchBytes: 10, generatedPaths: generated }),
  ).toBe("generated");
});

test("thresholds are the documented values", () => {
  expect(LARGE_DIFF_CHANGED_LINES).toBe(2_000);
  expect(LARGE_DIFF_PATCH_BYTES).toBe(400 * 1024);
});
