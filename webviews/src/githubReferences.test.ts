// Bare pull request references in agent replies (Leo 2026-10-20): `#22777`, `(#22664)` and
// `owner/repo#123` are links; GitHub numbers start at 1, and a URL fragment, an HTML entity or a
// word glued to the `#` is not a reference.
import { describe, expect, test } from "bun:test";
import { githubReferences, latestMentionedRepository, mentionedRepository } from "./githubReferences";

const REPO = "manaflow-ai/cmux";

describe("githubReferences", () => {
  const cases: Array<[name: string, text: string, refs: Array<[text: string, href: string]>]> = [
    ["bare number", "landed in #22777", [["#22777", `https://github.com/${REPO}/issues/22777`]]],
    ["in parentheses", "fix the bar (#22664)", [["#22664", `https://github.com/${REPO}/issues/22664`]]],
    ["qualified", "see owner/repo#123", [["owner/repo#123", "https://github.com/owner/repo/issues/123"]]],
    ["word glued to #", "foo#12", []],
    ["number zero", "a/b#0 and #0", []],
    ["leading zero", "a/b#012 and #012", []],
    ["more than ten digits", "a/b#12345678901 and #12345678901", []],
    ["letters after the number", "#12abc", []],
    ["URL fragment", "https://x.com/#12", []],
    ["HTML entity", "&#123; and &#x7b;", []],
    [
      "at line start (a heading needs a space)",
      "#1 first\n#2 second",
      [
        ["#1", `https://github.com/${REPO}/issues/1`],
        ["#2", `https://github.com/${REPO}/issues/2`],
      ],
    ],
    [
      "repository with dots",
      "vercel/next.js#123",
      [["vercel/next.js#123", "https://github.com/vercel/next.js/issues/123"]],
    ],
    [
      "repository with dashes and underscores",
      "my-org/my_repo.v2#7",
      [["my-org/my_repo.v2#7", "https://github.com/my-org/my_repo.v2/issues/7"]],
    ],
    ["trailing period", "fixed in #12.", [["#12", `https://github.com/${REPO}/issues/12`]]],
    [
      "trailing comma",
      "#12, #13",
      [
        ["#12", `https://github.com/${REPO}/issues/12`],
        ["#13", `https://github.com/${REPO}/issues/13`],
      ],
    ],
    ["trailing parenthesis", "(see a/b#3)", [["a/b#3", "https://github.com/a/b/issues/3"]]],
  ];
  test.each(cases)("%s", (_name, text, refs) => {
    expect(githubReferences(text, REPO).map((ref) => [ref.text, ref.href])).toEqual(refs);
  });

  test("a bare number needs a repository; a qualified one does not", () => {
    expect(githubReferences("#12 and a/b#3").map((ref) => ref.text)).toEqual(["a/b#3"]);
  });

  test("references can link to the pull request address", () => {
    expect(githubReferences("#5 and a/b#6", REPO, "pull").map((ref) => ref.href)).toEqual([
      `https://github.com/${REPO}/pull/5`,
      "https://github.com/a/b/pull/6",
    ]);
  });
});

describe("mentionedRepository", () => {
  const cases: Array<[name: string, text: string, repository: string | undefined]> = [
    ["the last qualified reference", "see manaflow-ai/cmux#1 and vercel/next.js#2", "vercel/next.js"],
    ["a reference after a URL", "https://github.com/a/b/pull/3 then c/d#4", "c/d"],
    ["a URL after a reference", "c/d#4 then https://github.com/a/b/pull/3", "a/b"],
    ["a URL without a scheme", "cloned github.com/a/b.git", "a/b"],
    ["a URL ending a sentence", "it lives at https://github.com/a/b.", "a/b"],
    ["a .git URL ending a sentence", "clone https://github.com/a/b.git.", "a/b"],
    ["github.com's own pages", "open https://github.com/login/device or github.com/settings/tokens", undefined],
    ["an organization page", "see github.com/orgs/manaflow-ai/projects/3", undefined],
    ["a markdown link", "[the PR](https://github.com/a/b/pull/9)", "a/b"],
    ["a code span", "run `gh pr view a/b#1`", undefined],
    ["a fenced block", "```\na/b#1 https://github.com/c/d\n```", undefined],
    ["a bare number only", "landed in #12", undefined],
    ["nothing", "plain words", undefined],
  ];
  test.each(cases)("%s", (_name, text, repository) => {
    expect(mentionedRepository(text)).toBe(repository);
  });
});

describe("latestMentionedRepository", () => {
  test("the latest text with a mention wins; code and empty texts are skipped", () => {
    expect(latestMentionedRepository(["x/y#1", "plain", undefined, "`a/b#1`"])).toBe("x/y");
    expect(latestMentionedRepository(["x/y#1", "then github.com/p/q/issues/2"])).toBe("p/q");
    expect(latestMentionedRepository([])).toBeUndefined();
  });
});
