// l10n-allow-file: fixture timestamps and English hover labels, not shipped UI.
// A clock time anywhere in an agent's prose is hoverable, not only right after "at" (Leo,
// 2026-11-07, on "...at 03:22..." with no hover: "we should probably be able to just detect this
// as like, oh yeah, this is a timestamp"). Numbers that only look like clock times stay plain.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";
import { timestampHoverLabel } from "./timeHoverModel";

// Local-zone rows read in the person's zone; this one is on standard time (UTC-8) on 2026-11-07.
process.env.TZ = "America/Los_Angeles";

// 23:00Z is 3:00 PM PST.
const sent = Date.parse("2026-11-07T23:00:00Z");

function times(markdown: string, messageAt = sent): Array<[string, string]> {
  const html = renderToStaticMarkup(<Markdown messageAt={messageAt}>{markdown}</Markdown>);
  return [...html.matchAll(/<time\b[^>]*dateTime="([^"]+)"[^>]*>([^<]*)<\/time>/g)].map((match) => [
    match[2]!,
    match[1]!,
  ]);
}

const DETECTED: ReadonlyArray<{ text: string; times: Array<[string, string]> }> = [
  // A bare 24-hour time is the reader's zone, the occurrence nearest the message.
  { text: "deploy finished 03:22, the rest is queued", times: [["03:22", "2026-11-07T11:22:00.000Z"]] },
  { text: "the 23:55 meeting", times: [["23:55", "2026-11-08T07:55:00.000Z"]] },
  { text: "14:40: build started", times: [["14:40", "2026-11-07T22:40:00.000Z"]] },
  {
    text: "started 14:40, rerun 15:14:09.",
    times: [
      ["14:40", "2026-11-07T22:40:00.000Z"],
      ["15:14:09", "2026-11-07T23:14:09.000Z"],
    ],
  },
  {
    text: "the window is 10:00-12:00",
    times: [
      ["10:00", "2026-11-07T18:00:00.000Z"],
      ["12:00", "2026-11-07T20:00:00.000Z"],
    ],
  },
  { text: "(Leo's case) n at 03:22 t", times: [["03:22", "2026-11-07T11:22:00.000Z"]] },
  // A date fixes the day; no zone means the reader's.
  { text: "logged 2026-11-07 15:04 by the worker", times: [["2026-11-07 15:04", "2026-11-07T23:04:00.000Z"]] },
  { text: "logged 2026-11-07T15:04.", times: [["2026-11-07T15:04", "2026-11-07T23:04:00.000Z"]] },
  { text: "at 2026-11-06 15:04:30 UTC", times: [["2026-11-06 15:04:30 UTC", "2026-11-06T15:04:30.000Z"]] },
  { text: "since Nov 7 15:04", times: [["Nov 7 15:04", "2026-11-07T23:04:00.000Z"]] },
  { text: "since Nov 7, 2026 at 3:22 PM", times: [["Nov 7, 2026 at 3:22 PM", "2026-11-07T23:22:00.000Z"]] },
  { text: "on 7 Nov 15:04", times: [["7 Nov 15:04", "2026-11-07T23:04:00.000Z"]] },
  { text: "November 8th, 09:00 works", times: [["November 8th, 09:00", "2026-11-08T17:00:00.000Z"]] },
  // A date with no year is the year nearest the message.
  { text: "Jan 2 09:00", times: [["Jan 2 09:00", "2027-01-02T17:00:00.000Z"]] },
  // An explicit offset keeps its zone.
  { text: "lands 15:04+02:00", times: [["15:04+02:00", "2026-11-07T13:04:00.000Z"]] },
  { text: "lands 15:04 -0800", times: [["15:04 -0800", "2026-11-07T23:04:00.000Z"]] },
  { text: "lands 15:04 UTC+2", times: [["15:04 UTC+2", "2026-11-07T13:04:00.000Z"]] },
  { text: "lands 20:30 GMT", times: [["20:30 GMT", "2026-11-07T20:30:00.000Z"]] },
  // An hour without a leading zero or AM/PM could be either half of the day: the nearer one.
  { text: "let's sync at 3:22", times: [["3:22", "2026-11-07T23:22:00.000Z"]] },
  { text: "done by 6:05", times: [["6:05", "2026-11-08T02:05:00.000Z"]] },
];

for (const row of DETECTED) {
  test(`detects a clock time: ${row.text}`, () => {
    expect(times(row.text)).toEqual(row.times);
  });
}

const PLAIN = [
  // Ratios and scores.
  "a 16:9 screen",
  "a 16:10 display",
  "aspect ratio 16:10",
  "the ratio is 21:9",
  "won 3:1",
  "won 21:15 in the final",
  "the final score was 2:1",
  "they lead 12:10",
  // line:col and paths.
  "foo.ts:12:30",
  "see :12:30",
  "src/app.ts:12:30: error TS2322",
  "line 12:30",
  "at /tmp/12:30/x",
  // Durations.
  "took 01:23:45",
  "elapsed 00:12:30",
  "01:23:45 elapsed",
  "the clip is 1:23:45",
  "12:30 left in the quarter",
  "at 1:30 into the video",
  "3:22",
  // References and versions.
  "John 3:16",
  "Psalm 23:10",
  "Genesis 12:30",
  "Matthew 5:3-10",
  "v1.12:30",
  "build23:55",
  "id-12:30",
  "T-10:00",
  // Ports, addresses, URLs.
  "localhost:8080",
  "127.0.0.1:22",
  "fe80::12:30",
  "12:30::1",
  "00:1a:2b:3c:4d:5e",
  "10:20:30:40",
  "https://example.com/at/12:30",
  // A zone name it cannot place stays plain rather than reading in the wrong zone.
  "lands 15:04 PST",
  // Code.
  "`15:04`",
  "```text\ndeploy finished 15:04\n```",
];

test("numbers that only look like clock times stay plain", () => {
  const hits = PLAIN.filter((text) => times(text).length > 0);
  expect(hits).toEqual([]);
});

test("the hover gives the full local date and time, then how far away it is", () => {
  const [[, iso]] = times("deploy finished 15:14");
  expect(timestampHoverLabel(Date.parse(iso!), sent, "en", sent)).toBe("Nov 7, 3:14 PM PST, in 14 min");
  expect(timestampHoverLabel(Date.parse("2026-11-07T22:54:00Z"), sent, "en", sent)).toBe(
    "Nov 7, 2:54 PM PST, 6 min ago",
  );
});
