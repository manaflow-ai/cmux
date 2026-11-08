// Review from link (prReview.ts): only a GitHub pull request's address takes a review, in its plain
// form, and the side chat's prompt names it and the `cmux git review` steps the agent runs.
import { expect, test } from "bun:test";
import { pullRequestUrl, reviewPrompt } from "./prReview";

test("a pull request's address is kept in its plain form", () => {
  expect(pullRequestUrl("https://github.com/manaflow-ai/cmux/pull/482")).toBe(
    "https://github.com/manaflow-ai/cmux/pull/482",
  );
  // A tab of it, a query and a fragment name the same pull request.
  expect(pullRequestUrl("https://github.com/manaflow-ai/cmux/pull/482/files?w=1#diff-abc")).toBe(
    "https://github.com/manaflow-ai/cmux/pull/482",
  );
  expect(pullRequestUrl("  https://github.com/a-b/c.d_e/pull/7/commits  ")).toBe("https://github.com/a-b/c.d_e/pull/7");
});

test("anything but a GitHub pull request is refused", () => {
  for (const text of [
    "https://github.com/manaflow-ai/cmux/issues/482",
    "https://github.com/manaflow-ai/cmux",
    "https://github.com/manaflow-ai/cmux/pulls",
    "https://github.com/manaflow-ai/cmux/pull/0",
    "https://github.com/manaflow-ai/cmux/pull/12abc",
    "http://github.com/manaflow-ai/cmux/pull/482",
    "https://gitlab.com/manaflow-ai/cmux/pull/482",
    "https://github.com.evil.test/manaflow-ai/cmux/pull/482",
    "https://evil.test/github.com/manaflow-ai/cmux/pull/482",
    "https://user@github.com/manaflow-ai/cmux/pull/482",
    "https://github.com:8443/manaflow-ai/cmux/pull/482",
    "https://github.com/manaflow-ai/../pull/482",
    "github.com/manaflow-ai/cmux/pull/482",
    "not a url",
    "",
  ]) {
    expect(pullRequestUrl(text)).toBeUndefined();
  }
});

test("the prompt names the pull request and the review commands, and says not to post", () => {
  const url = "https://github.com/manaflow-ai/cmux/pull/482";
  const prompt = reviewPrompt(url);
  expect(prompt.startsWith(`Review the pull request ${url}. Don't post anything to GitHub`)).toBe(true);
  expect(prompt).toContain(`\`cmux git review start ${url}\``);
  expect(prompt).toContain("`cmux git review comment --path <folder> --file <path> --line <n> --message");
  expect(prompt).toContain("`--start-line <m>`");
  expect(prompt).toContain("`--side old`");
  expect(prompt).toContain("`cmux browser open-diff-viewer --path <folder>`");
  expect(prompt.split("\n")).toHaveLength(6);
});
