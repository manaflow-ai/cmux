import { expect, test } from "bun:test";
import { filterConversation, filterCounts } from "./conversationFilter";
import { mockBlockedDetails } from "./mockReadiness";

const entries = mockBlockedDetails.conversation;
const viewer = mockBlockedDetails.viewer;

test("newest first by default; oldest first on the toggle", () => {
  const newest = filterConversation(entries, "all", "newest", viewer).map((entry) => entry.at);
  expect(newest).toEqual([...newest].sort().reverse());
  const oldest = filterConversation(entries, "all", "oldest", viewer).map((entry) => entry.at);
  expect(oldest).toEqual([...oldest].sort());
});

test("Unresolved keeps each review with only its open threads' comments", () => {
  const kept = filterConversation(entries, "unresolved", "newest", viewer);
  expect(kept.map((entry) => entry.author)).toEqual(["monalisa"]);
  expect(kept[0]!.comments.map((comment) => comment.line)).toEqual([31]);
  // The read is untouched.
  expect(entries[1]!.comments).toHaveLength(2);
});

test("Mine keeps the viewer's entries, whatever the login's case", () => {
  expect(filterConversation(entries, "mine", "newest", "OctoCat").every((entry) => entry.author === "octocat")).toBe(
    true,
  );
  expect(filterConversation(entries, "mine", "newest", undefined)).toEqual([]);
  expect(filterCounts(entries, viewer)).toEqual({ all: 4, unresolved: 1, mine: 3 });
});
