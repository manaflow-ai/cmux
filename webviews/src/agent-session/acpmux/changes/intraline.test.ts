import { describe, expect, test } from "bun:test";
import { diffHunks, diffLines, type DiffEdit } from "../diff";
import { changedPairs, intralineMode, lineSimilarity } from "./intraline";

const edit = (before: string, after: string): DiffEdit => ({
  toolId: "t1",
  hunks: diffHunks(diffLines(before, after)),
  numbered: true,
});

describe("lineSimilarity", () => {
  test("a line with one word changed is mostly the same line", () => {
    expect(
      lineSimilarity("  return request<T>(url, { signal });", "return request<T>(url, { body });"),
    ).toBeGreaterThan(0.8);
  });
  test("two unrelated lines share little", () => {
    expect(lineSimilarity("const send = async () => {", 'method: options.method ?? "GET",')).toBeLessThan(0.3);
  });
});

describe("intralineMode", () => {
  test("lines edited in place get word marks", () => {
    const before = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
    const after = "const a = 10;\nconst b = 20;\nconst c = 3;\n";
    expect([changedPairs(edit(before, after)).length, intralineMode(edit(before, after))]).toEqual([2, "word-alt"]);
  });

  test("a block wrapped in a new function pairs shifted lines, so it gets no word marks", () => {
    const before = [
      "const response = await fetch(url, {",
      '  method: options.method ?? "GET",',
      "  signal: options.signal,",
      "});",
      "return (await response.json()) as T;",
      "",
    ].join("\n");
    const after = [
      "const send = async () => {",
      "  const response = await fetch(url, {",
      '    method: options.method ?? "GET",',
      "    signal: options.signal,",
      "  });",
      "  return (await response.json()) as T;",
      "};",
      "",
    ].join("\n");
    expect(intralineMode(edit(before, after))).toBe("none");
  });

  test("an edit that only adds or only removes lines has nothing to pair", () => {
    expect([changedPairs(edit("a\n", "a\nb\n")), intralineMode(edit("a\n", "a\nb\n"))]).toEqual([[], "word-alt"]);
  });
});
