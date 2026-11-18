import { expect, test } from "bun:test";
import { customRecency, liveMatches, plainWords, recencyOf, recencyOnly, withRecency } from "./chatQueryTerms";

// The When menu writes its `since:` into the search (ask-b75ea23533), and reads it back from there.
test("the menu's choice is the query's since:", () => {
  expect(withRecency("", "week")).toBe("since:7d");
  expect(withRecency("sidebar", "day")).toBe("sidebar since:1d");
  expect(withRecency("sidebar since:1d", "month")).toBe("sidebar since:30d");
  expect(withRecency("since:7d sidebar", "any")).toBe("sidebar");
  expect(recencyOf("sidebar since:7d")).toBe("week");
  expect(recencyOf("sidebar")).toBe("any");
});

test("a since: typed by hand is shown as typed, and the menu replaces it", () => {
  expect(customRecency("fix since:3d")).toBe(true);
  expect(customRecency("fix since:7d")).toBe(false);
  expect(recencyOf("after:3d")).toBe("any");
  expect(withRecency("fix after:3d", "day")).toBe("fix since:1d");
});

test("a live chat passes the query as acpmux's filter would", () => {
  const chat = { title: "Fix the new tab sidebar", harness: "codex" };
  expect(liveMatches(chat, "sidebar fix")).toBe(true);
  expect(liveMatches(chat, "harness:codex since:7d")).toBe(true);
  expect(liveMatches(chat, "harness:claude")).toBe(false);
  expect(liveMatches(chat, "sidebar -tab")).toBe(false);
  expect(liveMatches(chat, 'title:"new tab"')).toBe(true);
  expect(liveMatches(chat, '"sidebar fix"')).toBe(false);
  expect(liveMatches(chat, "in:cmux")).toBe(false);
});

test("When alone is not a search; the last since: counts", () => {
  expect(recencyOnly("since:7d")).toBe(true);
  expect(recencyOnly("fix since:7d")).toBe(false);
  expect(recencyOnly("")).toBe(false);
  expect(recencyOf("since:7d since:1d")).toBe("day");
});

test("live chats are matched with the plain words only", () => {
  expect(plainWords('Fix since:7d harness:codex in:cmux -draft "the sidebar"')).toBe("fix the sidebar");
  expect(plainWords("http://x.dev - --flag")).toBe("http://x.dev - --flag");
});
