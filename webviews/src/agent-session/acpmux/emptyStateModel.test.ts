import { expect, test } from "bun:test";
import { contextualStarts } from "./emptyStateModel";
import type { Translate } from "./i18n";

// A start's pick fills the composer and sends nothing: a folder's last prompt can be "merge it"
// or "delete the branch", which one click must never replay into a new chat.
const t: Translate = (key, values) => `${key}${values?.number === undefined ? "" : `:${values.number}`}`;
const HOUR = 3_600_000;

test("a pick only prefills the composer: the last prompt and the pull request review alike", () => {
  const prefilled: string[] = [];
  const starts = contextualStarts({
    folder: "/src/app/",
    sessions: [
      { cwd: "/src/app", recentPrompt: "fix the parser", updatedAt: 1 },
      { cwd: "/src/app", recentPrompt: "delete the branch", updatedAt: 10 * HOUR - 2 * HOUR },
      { cwd: "/src/other", recentPrompt: "not this folder", updatedAt: 10 * HOUR },
    ],
    pullRequest: 42,
    prefill: (text) => prefilled.push(text),
    t,
    now: 10 * HOUR,
    language: "en",
  });
  expect(starts.map((start) => start.id)).toEqual(["last-prompt", "review-pull-request"]);
  expect(starts[0]!.label).toBe("delete the branch");
  // Its age is the source chat's, not a constant "now".
  expect(starts[0]!.time).toBe("2 hours ago");
  expect(starts[1]!.time).toBeUndefined();
  for (const start of starts) start.onPick();
  expect(prefilled).toEqual(["delete the branch", "emptyState.reviewPullRequestPrompt:42"]);
});

test("ids stay unique when two starts read the same", () => {
  const starts = contextualStarts({
    folder: "/src/app",
    sessions: [{ cwd: "/src/app", recentPrompt: "Tour this repo", updatedAt: 5 }],
    tour: { label: "Tour this repo", onTake: () => undefined },
    prefill: () => undefined,
    t,
    now: 5,
  });
  expect(new Set(starts.map((start) => start.id)).size).toBe(starts.length);
});
