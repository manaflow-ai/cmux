import { describe, expect, it } from "vitest";
import type { ReplaceDiffEntry } from "../diff-types";
import {
  isLockfileDiffEntry,
  isLockfilePath,
} from "./is-lockfile-path";

describe("isLockfilePath", () => {
  it("detects common lockfile basenames", () => {
    expect(isLockfilePath("pnpm-lock.yaml")).toBe(true);
    expect(isLockfilePath("apps/web/yarn.lock")).toBe(true);
    expect(isLockfilePath("Repo:package-lock.json")).toBe(true);
    expect(isLockfilePath("packages/api/Pipfile.lock")).toBe(true);
    expect(isLockfilePath("apps/mobile\\Gemfile.lock")).toBe(true);
    expect(isLockfilePath("C:/tmp/cargo.lock")).toBe(true);
  });

  it("returns false for non-lockfiles", () => {
    expect(isLockfilePath("src/index.ts")).toBe(false);
    expect(isLockfilePath("docs/requirements.txt")).toBe(false);
    expect(isLockfilePath("")).toBe(false);
    expect(isLockfilePath(undefined)).toBe(false);
  });
});

describe("isLockfileDiffEntry", () => {
  it("matches lockfiles on either side of the diff", () => {
    const entry: ReplaceDiffEntry = {
      filePath: "apps/web/yarn.lock",
      status: "modified",
      additions: 10,
      deletions: 4,
      isBinary: false,
    };
    expect(isLockfileDiffEntry(entry)).toBe(true);

    const rename: ReplaceDiffEntry = {
      filePath: "docs/README.md",
      oldPath: "docs/yarn.lock",
      status: "renamed",
      additions: 0,
      deletions: 0,
      isBinary: false,
    };
    expect(isLockfileDiffEntry(rename)).toBe(true);
  });

  it("returns false for regular files", () => {
    const entry: ReplaceDiffEntry = {
      filePath: "src/components/Button.tsx",
      status: "modified",
      additions: 5,
      deletions: 2,
      isBinary: false,
    };
    expect(isLockfileDiffEntry(entry)).toBe(false);
  });
});
