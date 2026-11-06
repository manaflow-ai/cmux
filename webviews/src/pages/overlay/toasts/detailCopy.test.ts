// The toast detail's plain words (moved from CmuxToastDetailCopyTests.swift).
import { describe, expect, test } from "bun:test";
import { codes, plainDetail, wordsKey } from "./detailCopy";

const t = (key: string) => `<${key}>`;
const noSpace = "cannot copy the build to the machine: fs.no_space: no space left on the device";

describe("plainDetail", () => {
  test("a known code reads in plain words, with the code kept", () => {
    expect(plainDetail(noSpace, t)).toEqual({ text: "<overlay.toasts.detail.noSpace>", code: "fs.no_space" });
  });

  test("every known code has words", () => {
    for (const code of ["fs.no_space", "disk_full", "fs.read_only", "fs.permission_denied", "fs.too_large"]) {
      expect(plainDetail(`push failed: ${code}.`, t).code).toBe(code);
    }
  });

  test("a detail with no known code stays as it came", () => {
    const raw = "the SSH connection timed out after 10 s";
    expect(plainDetail(raw, t)).toEqual({ text: raw });
    expect(wordsKey("constructor")).toBeUndefined();
  });

  test("a detail of several lines stays as it came, even with a known code", () => {
    const raw = "lab-mini: fs.no_space\ndev: timed out";
    expect(plainDetail(raw, t)).toEqual({ text: raw });
    expect(plainDetail("a: fs.no_space b: x", t)).toEqual({ text: "a: fs.no_space b: x" });
  });

  test("codes are code-shaped runs without edge dots", () => {
    expect(codes("...: fs.no_space: no space.")).toEqual(["fs.no_space", "no", "space"]);
  });
});
