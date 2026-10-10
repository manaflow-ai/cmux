import { expect, test } from "bun:test";
import { minutesAgo } from "../../gallery/clock";
import { session } from "../../gallery/fixtures/acpmux";
import { homeLists } from "./HomeLists";

test("homeLists excludes unlisted and not-ready sessions, then caps each section", () => {
  const current = session({ sessionId: "current", status: "waiting", updatedAt: minutesAgo(0) });
  const input = Array.from({ length: 4 }, (_, index) =>
    session({
      sessionId: `input-${index}`,
      title: `Waiting ${index}`,
      status: "waiting",
      updatedAt: minutesAgo(index + 1),
    }),
  );
  const review = Array.from({ length: 4 }, (_, index) =>
    session({
      sessionId: `review-${index}`,
      title: `Review ${index}`,
      updatedAt: minutesAgo(index + 1),
      pullRequest: { number: 19100 + index, title: `Review ${index}`, state: "open", reviewReady: true },
    }),
  );
  const hidden = [
    session({ sessionId: "archived", status: "waiting", archived: true }),
    session({ sessionId: "side", status: "waiting", side: true }),
    session({
      sessionId: "draft",
      pullRequest: { number: 19110, title: "Draft", state: "draft", reviewReady: true },
    }),
    session({
      sessionId: "not-ready",
      pullRequest: { number: 19111, title: "Not ready", state: "open", reviewReady: false },
    }),
  ];

  const result = homeLists([current, ...input, ...review, ...hidden], current.sessionId);
  expect(result.input.map(({ sessionId }) => sessionId)).toEqual(["input-0", "input-1", "input-2"]);
  expect(result.review.map(({ sessionId }) => sessionId)).toEqual(["review-0", "review-1", "review-2"]);
  expect([...result.input, ...result.review].some(({ sessionId }) => sessionId === current.sessionId)).toBe(false);
  expect([...result.input, ...result.review].map(({ sessionId }) => sessionId)).not.toContain("archived");
  expect([...result.input, ...result.review].map(({ sessionId }) => sessionId)).not.toContain("side");
  expect([...result.input, ...result.review].map(({ sessionId }) => sessionId)).not.toContain("draft");
  expect([...result.input, ...result.review].map(({ sessionId }) => sessionId)).not.toContain("not-ready");
});
