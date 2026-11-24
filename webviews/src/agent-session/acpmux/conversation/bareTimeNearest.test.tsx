// l10n-allow-file: fixture timestamps and English hover labels, not shipped UI.
// A time with no date means the occurrence nearest the message's own send time, within 12 hours
// either way (Leo, 2026-11-07, on "08:36Z" in a message sent at 08:21Z hovering as "24 hr ago":
// "It's too biased towards the past here."). Every time-only form follows the same rule.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";
import { timestampHoverLabel } from "./timeHoverModel";

// Local-zone rows read in the person's zone; this one is on standard time on 2026-11-07.
process.env.TZ = "America/Los_Angeles";

const at = (iso: string) => Date.parse(iso);

function dateTimes(markdown: string, messageAt: number): string[] {
  const html = renderToStaticMarkup(<Markdown messageAt={messageAt}>{markdown}</Markdown>);
  return [...html.matchAll(/<time\b[^>]*dateTime="([^"]+)"/g)].map((match) => match[1]!);
}

const CASES: ReadonlyArray<{ name: string; text: string; sent: string; resolves: string }> = [
  // Leo's case: written 15 minutes before the time.
  {
    name: "future, same day (Z)",
    text: "At about 08:36Z, after the",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T08:36:00.000Z",
  },
  {
    name: "future, same day (UTC)",
    text: "lands at 11:00 UTC",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T11:00:00.000Z",
  },
  {
    name: "past, same day",
    text: "it failed at 08:06Z",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T08:06:00.000Z",
  },
  {
    name: "past, same day, hours back",
    text: "started at 01:30:15Z",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T01:30:15.000Z",
  },
  {
    name: "crosses midnight back",
    text: "the last run was 23:50Z",
    sent: "2026-11-07T00:10:00Z",
    resolves: "2026-11-06T23:50:00.000Z",
  },
  {
    name: "crosses midnight forward",
    text: "the next run is 00:05Z",
    sent: "2026-11-07T23:55:00Z",
    resolves: "2026-11-08T00:05:00.000Z",
  },
  {
    name: "12h with UTC, future",
    text: "at 8:36 AM UTC",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T08:36:00.000Z",
  },
  {
    name: "12h with UTC, past midnight",
    text: "by 12:05 am UTC",
    sent: "2026-11-07T23:55:00Z",
    resolves: "2026-11-08T00:05:00.000Z",
  },
  // 08:21Z is 00:21 PST.
  {
    name: "local 12h, past (at 9pm)",
    text: "we met at 9pm",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T05:00:00.000Z",
  },
  {
    name: "local 12h, future",
    text: "back by 1:30 a.m.",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T09:30:00.000Z",
  },
  {
    name: "local 12h, noon",
    text: "lunch at 12 PM",
    sent: "2026-11-07T18:00:00Z",
    resolves: "2026-11-07T20:00:00.000Z",
  },
  {
    name: "local 24h, past",
    text: "deployed at 23:30",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T07:30:00.000Z",
  },
  {
    name: "local 24h, future",
    text: "rerun at 00:40",
    sent: "2026-11-07T08:21:00Z",
    resolves: "2026-11-07T08:40:00.000Z",
  },
];

for (const row of CASES) {
  test(`a bare time resolves nearest the message: ${row.name}`, () => {
    expect(dateTimes(row.text, at(row.sent))).toEqual([row.resolves]);
  });
}

test("a time exactly 12 hours away reads as the earlier one", () => {
  expect(dateTimes("at 20:21Z", at("2026-11-07T08:21:00Z"))).toEqual(["2026-11-06T20:21:00.000Z"]);
});

test("bare numbers that are not clock times stay plain", () => {
  const sent = at("2026-11-07T08:21:00Z");
  // "the 23:55 meeting" is a time now (bareClockDetect.test.tsx): a clock time hovers anywhere in prose.
  for (const text of ["a 16:9 screen", "score 24:17", "I am 5", "2 PMs joined", "at 16:9 ratio"]) {
    expect(dateTimes(text, sent)).toEqual([]);
  }
});

const sent = at("2026-11-07T08:21:00Z");
const ahead = at("2026-11-07T08:36:00Z");

test("a time still ahead of now says how long until it", () => {
  expect(timestampHoverLabel(ahead, sent, "en", sent)).toBe("Nov 7, 12:36 AM PST, in 15 min");
  expect(timestampHoverLabel(at("2026-11-07T11:21:00Z"), sent, "en", sent)).toBe("Nov 7, 3:21 AM PST, in 3 hr");
});

test("a time after its message, read once it has passed, says how long after the message", () => {
  expect(timestampHoverLabel(ahead, at("2026-11-07T12:00:00Z"), "en", sent)).toBe(
    "Nov 7, 12:36 AM PST, 15 min after this message",
  );
});

test("a time before its message still says how long ago", () => {
  expect(timestampHoverLabel(at("2026-11-07T08:06:00Z"), at("2026-11-07T08:21:00Z"), "en", sent)).toBe(
    "Nov 7, 12:06 AM PST, 15 min ago",
  );
});
