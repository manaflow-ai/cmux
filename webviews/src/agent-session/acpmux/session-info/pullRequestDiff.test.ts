import { describe, expect, test } from "bun:test";
import { pullRequestDiffUrl } from "./pullRequestDiff";

describe("pullRequestDiffUrl", () => {
  test("a pull request link, or one of its tabs, gives its Files tab", () => {
    expect(pullRequestDiffUrl("https://github.com/manaflow-ai/cmux/pull/36101")).toBe(
      "https://github.com/manaflow-ai/cmux/pull/36101/files",
    );
    expect(pullRequestDiffUrl("https://github.com/manaflow-ai/cmux/pull/36101/checks")).toBe(
      "https://github.com/manaflow-ai/cmux/pull/36101/files",
    );
  });

  test("anything else has no diff", () => {
    for (const other of [
      undefined,
      "https://github.com/manaflow-ai/cmux/issues/1",
      "https://github.com/manaflow-ai/cmux/pull/1#issuecomment-2",
      "https://github.com/manaflow-ai/cmux/pull/1?w=1",
      "https://github.com/manaflow-ai/cmux/pull/01",
      "https://github.com/../cmux/pull/1",
      "https://github.com/-x/cmux/pull/1",
      `https://github.com/${"a".repeat(101)}/cmux/pull/1`,
      "http://github.com/a/b/pull/1",
      "https://gitlab.com/a/b/pull/1",
    ])
      expect(pullRequestDiffUrl(other)).toBeUndefined();
  });
});
