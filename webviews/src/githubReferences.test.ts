import { describe, expect, test } from "bun:test";
import { githubReferences } from "./githubReferences";

describe("githubReferences", () => {
  test("resolves bare references from the workspace repository", () => {
    expect(githubReferences("Fix #12 and #34", "manaflow-ai/cmux").map((ref) => ref.href)).toEqual([
      "https://github.com/manaflow-ai/cmux/issues/12",
      "https://github.com/manaflow-ai/cmux/issues/34",
    ]);
  });

  test("keeps qualified references independent of the workspace", () => {
    expect(githubReferences("See manaflow-ai/cmux#99").map((ref) => ref.href)).toEqual([
      "https://github.com/manaflow-ai/cmux/issues/99",
    ]);
  });

  test("does not match embedded references", () => {
    expect(githubReferences("word#12 path/#13 foo/bar#14x", "manaflow-ai/cmux")).toEqual([]);
  });
});
