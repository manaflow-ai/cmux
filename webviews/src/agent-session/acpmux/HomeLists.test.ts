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
      indicator: "input",
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
  // Every waiting chat is in the inbox, newest first: none is capped away.
  expect(result.waiting.map(({ sessionId }) => sessionId)).toEqual(["input-0", "input-1", "input-2", "input-3"]);
  expect(result.review.map(({ sessionId }) => sessionId)).toEqual(["review-0", "review-1", "review-2"]);
  const ids = [...result.waiting, ...result.review].map(({ sessionId }) => sessionId);
  for (const hidden of [current.sessionId, "archived", "side", "draft", "not-ready"]) expect(ids).not.toContain(hidden);
});

test("the inbox lists each other chat's open ask by its permission, never the current chat's", () => {
  const current = session({ sessionId: "current", pendingPermissions: 1, updatedAt: minutesAgo(0) });
  const other = session({ sessionId: "other", title: "Other", pendingPermissions: 2, updatedAt: minutesAgo(3) });
  const side = session({ sessionId: "side", side: true, pendingPermissions: 1 });
  const ask = (sessionId: string, permissionId: string, at: number) => ({
    sessionId,
    at,
    permission: {
      permissionId,
      title: `Run ${permissionId}`,
      pending: true,
      options: [
        { id: `${permissionId}-yes`, name: "Yes", kind: "allow_once", allow: true },
        { id: `${permissionId}-always`, name: "Always", kind: "allow_always", allow: true },
        { id: `${permissionId}-no`, name: "No", kind: "reject_once", allow: false },
      ],
    },
  });
  const { waiting } = homeLists([current, other, side], current.sessionId, [
    ask("current", "p-current", minutesAgo(0)),
    ask("other", "p-old", minutesAgo(4)),
    ask("other", "p-new", minutesAgo(2)),
    ask("side", "p-side", minutesAgo(1)),
  ]);
  expect(waiting.map(({ id }) => id)).toEqual(["acpmux:p-new", "acpmux:p-old"]);
  // One click answers once, never always: Always allow is the chat's card's to give.
  expect(waiting[0]!.answers.map(({ id }) => id)).toEqual(["p-new-yes", "p-new-no"]);
});
