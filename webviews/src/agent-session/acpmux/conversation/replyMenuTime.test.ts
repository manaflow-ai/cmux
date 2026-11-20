// l10n-allow-file: timestamp expectations exercise Intl formatting.
import { expect, test } from "bun:test";
import { exactTime, replyMenuTime } from "./relativeTime";

test("the reply menu shows Today or Yesterday before the time, by calendar day", () => {
  const now = new Date(2026, 10, 4, 0, 5).getTime();
  expect(replyMenuTime(new Date(2026, 10, 4, 0, 1).getTime(), now, "en-US")).toBe("Today, 12:01 AM");
  expect(replyMenuTime(new Date(2026, 10, 3, 23, 59).getTime(), now, "en-US")).toBe("Yesterday, 11:59 PM");
  const older = new Date(2026, 10, 2, 17, 29).getTime();
  expect(replyMenuTime(older, now, "en-US")).toBe(exactTime(older, "en-US"));
});

test("the header uses the pane language and ignores an invalid timestamp", () => {
  const at = new Date(2026, 10, 4, 17, 29).getTime();
  expect(replyMenuTime(at, at, "de-DE")).toBe("Heute, 17:29");
  expect(replyMenuTime(Number.NaN, at, "en-US")).toBe("");
  expect(replyMenuTime(0, at, "en-US")).toBe("");
});
