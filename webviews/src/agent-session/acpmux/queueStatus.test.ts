// The failed turn's one status line in words (queueStatus.ts) and a queued surge digest's summary
// (surgeDigest.ts). Leo, 2026-11-23, on the raw "Paused after an error: API Error: 503 …" under
// "Retrying (1/4) after a capacity error": "this looks ass idk".
import { expect, test } from "bun:test";
import { translatorFor } from "./i18n";
import { countdownText, queueStatus } from "./queueStatus";
import { surgeDigestOf, surgeDigestText } from "./surgeDigest";

const t = translatorFor("en");
const ERROR = "API Error: 503 no non-exhausted claude accounts available; next account frees up in 10m";

test("a scheduled retry reads as its reason in words, the raw error kept for Details", () => {
  const status = queueStatus(t, { retry: { attempt: 1, of: 4, reason: "capacity" }, paused: true, error: ERROR });
  expect(status?.title).toBe("Waiting for capacity");
  expect(status?.retry?.attempt).toBe(1);
  expect(status?.error).toBe(ERROR);
  expect(queueStatus(t, { retry: { attempt: 2, of: 4 }, paused: false })?.title).toBe("Retrying after an error");
});

test("a pause with nothing retrying says it paused; neither says nothing", () => {
  expect(queueStatus(t, { paused: true, error: ERROR })).toEqual({ title: "Paused after an error", error: ERROR });
  expect(queueStatus(t, { paused: false, error: ERROR })).toBeUndefined();
});

test("the countdown reads as a clock", () => {
  expect(countdownText(9 * 60_000 + 42_000)).toBe("9:42");
  expect(countdownText(3_723_000)).toBe("1:02:03");
  expect(countdownText(-5)).toBe("0:00");
  expect(countdownText(400)).toBe("0:01");
});

test("acpmux's surge digest reads as its counts; any other prompt is no digest", () => {
  const digest = surgeDigestOf(
    "Held during a message surge: 29 message(s) in 23 thread(s) need you. Routine and handled ones stay in your inbox archive.\n- [pr:1] 2 msg from a: b",
  );
  expect(digest).toEqual({ messages: 29, threads: 23 });
  expect(surgeDigestText(t, digest!)).toBe("29 messages in 23 threads");
  expect(surgeDigestText(t, { messages: 3, threads: 1 })).toBe("3 messages in 1 thread");
  expect(surgeDigestText(t, { messages: 1, threads: 1 })).toBe("1 message in 1 thread");
  expect(surgeDigestOf("Held during a message surge, please read")).toBeUndefined();
});
