import { expect, test } from "bun:test";
import {
  nextRelativeTime,
  nextReplyTime,
  relativeTime,
  replyTime,
} from "../src/agent-session/acpmux/conversation/relativeTime";

const minute = 60_000;
const at = Date.UTC(2026, 9, 19, 9, 0, 23, 813);

test("relative labels wake on their first changed shared minute, including rounding and unit boundaries", () => {
  const ages = [
    0, 59, 60, 89, 90, 3599, 3600, 5399, 5400, 86399, 86400, 604799, 604800, 2591999, 2592000, 31535999, 31536000,
  ];
  for (const seconds of ages) {
    const now = Math.floor((at + seconds * 1000) / minute) * minute;
    const next = nextRelativeTime(at, now);
    expect(next % minute).toBe(0);
    expect(next).toBeGreaterThan(now);
    expect(relativeTime(at, next - minute, "en-US")).toBe(relativeTime(at, now, "en-US"));
    expect(relativeTime(at, next, "en-US")).not.toBe(relativeTime(at, now, "en-US"));
  }
});

test("a future message stays just now until its first age boundary", () => {
  const now = at - 5 * minute;
  const next = nextRelativeTime(at, Math.floor(now / minute) * minute);
  expect(next).toBeGreaterThan(at);
  expect(relativeTime(at, next - minute, "en-US")).toBe("just now");
  expect(relativeTime(at, next, "en-US")).toBe("1 minute ago");
});

test("exact reply labels stop after the year suffix is permanent", () => {
  const now = new Date(2026, 10, 3).getTime();
  const next = nextReplyTime(at, now);
  expect(next).toBe(new Date(2027, 0, 1).getTime());
  expect(replyTime(at, next - 1, "en-US")).toBe(replyTime(at, now, "en-US"));
  expect(replyTime(at, next, "en-US")).not.toBe(replyTime(at, now, "en-US"));
  expect(nextReplyTime(at, next)).toBe(Infinity);
});
