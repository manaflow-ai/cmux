// A pull request or issue address is a reference chip, as Claude desktop draws them (Leo
// 2026-10-19). LinkChips.tsx names the reference and takes the item's own title, for its hover card,
// from the page title cmux has for it.
import { expect, test } from "bun:test";
import { githubRefLabel, githubRefTitle } from "./LinkChips";

test("a pull request or issue address names its reference", () => {
  expect(githubRefLabel("https://github.com/manaflow-ai/cmux/pull/21738")).toBe("manaflow-ai/cmux#21738");
  expect(githubRefLabel("https://github.com/manaflow-ai/cmux/issues/13742#issuecomment-1")).toBe(
    "manaflow-ai/cmux#13742",
  );
  expect(githubRefLabel("https://github.com/manaflow-ai/cmux/pull/21738/files")).toBeUndefined();
  expect(githubRefLabel("https://github.com/manaflow-ai/cmux")).toBeUndefined();
  expect(githubRefLabel("https://example.com/a/b/pull/1")).toBeUndefined();
});

test("the card's title is the item's own, never GitHub's page furniture", () => {
  expect(
    githubRefTitle("Agent chat: links are blue by teamleaderleo · Pull Request #22350 · manaflow-ai/cmux · GitHub"),
  ).toBe("Agent chat: links are blue");
  expect(githubRefTitle("Links barely stand out · Issue #13742 · manaflow-ai/cmux")).toBe("Links barely stand out");
  expect(githubRefTitle("GitHub")).toBeUndefined();
  expect(githubRefTitle(undefined)).toBeUndefined();
});
