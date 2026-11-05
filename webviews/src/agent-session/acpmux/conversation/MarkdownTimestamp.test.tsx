// l10n-allow-file: fixture timestamps, not shipped UI.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";

const messageAt = Date.UTC(2026, 9, 24, 5, 30, 0);

function dateTimes(markdown: string, at = messageAt): string[] {
  const html = renderToStaticMarkup(<Markdown messageAt={at}>{markdown}</Markdown>);
  return [...html.matchAll(/<time\b[^>]*dateTime="([^"]+)"/g)].map((match) => match[1]!);
}

test("renders clock times, ISO timestamps, and UTC labels as hoverable times", () => {
  const html = renderToStaticMarkup(
    <Markdown messageAt={messageAt}>
      {
        "Started at 05:21Z, finished at 05:21:28Z, recorded 2026-10-24T05:21:28Z, shifted 2026-10-24T05:21:28-07:00, and noted 05:22 UTC."
      }
    </Markdown>,
  );

  expect((html.match(/class="[^"]*cv-time-hover[^"]*"/g) ?? []).length).toBe(5);
  expect((html.match(/tabindex="0"/g) ?? []).length).toBe(5);
  expect(html).toContain('aria-label="05:21Z,');
  expect(html).toContain("2026-10-24T05:21:00.000Z");
  expect(html).toContain("2026-10-24T05:21:28.000Z");
  expect(html).toContain("2026-10-24T12:21:28.000Z");
});

test("infers a bare UTC clock time from the nearest earlier message date", () => {
  const justAfterMidnight = Date.UTC(2026, 9, 24, 0, 10, 0);
  expect(dateTimes("The prior update was at 23:50Z.", justAfterMidnight)).toEqual(["2026-10-23T23:50:00.000Z"]);
  expect(dateTimes("The update was at 00:05Z.", justAfterMidnight)).toEqual(["2026-10-24T00:05:00.000Z"]);
});

test("leaves inline and fenced code timestamps unchanged", () => {
  const html = renderToStaticMarkup(
    <Markdown messageAt={messageAt}>
      {"Outside 05:21Z, but `05:22Z` stays code.\n\n```text\n05:23Z\n```\n\n05:24 UTC is outside."}
    </Markdown>,
  );

  expect((html.match(/class="[^"]*cv-time-hover[^"]*"/g) ?? []).length).toBe(2);
  expect(html).toContain('<code class="cv-code">05:22Z</code>');
  expect(html).toContain("05:23Z");
  expect(html).not.toContain('cv-time-hover">05:22Z');
  expect(html).not.toContain('cv-time-hover">05:23Z');
});

test("does not decorate timestamps inside Markdown or bare URL destinations", () => {
  const html = renderToStaticMarkup(
    <Markdown messageAt={messageAt}>
      {
        "[logs](https://example.com/2026-10-24T05:21:28Z) https://example.com/2026-10-24T05:22:28Z [quoted](https://example.com/O'Reilly/2026-10-24T05:22:58Z) [file](/tmp/2026-10-24T05:23:28Z.txt) [relative](docs/2026-10-24T05:24:28Z.txt)"
      }
    </Markdown>,
  );

  expect(html).toContain('href="https://example.com/2026-10-24T05:21:28Z"');
  expect(html).toContain('href="https://example.com/2026-10-24T05:22:28Z"');
  expect(html).toContain('href="https://example.com/O&#x27;Reilly/2026-10-24T05:22:58Z"');
  expect(html).toContain('data-path="/tmp/2026-10-24T05:23:28Z.txt"');
  expect(html).toContain('data-path="docs/2026-10-24T05:24:28Z.txt"');
  expect(html).not.toContain("%EE%80%80");
});

const postedAt = Date.UTC(2026, 9, 25, 2, 30, 0);

function sources(markdown: string, at = postedAt): string[] {
  const html = renderToStaticMarkup(<Markdown messageAt={at}>{markdown}</Markdown>);
  return [...html.matchAll(/<time\b[^>]*>([^<]*)<\/time>/g)].map((match) => match[1]!);
}

test("a zone after a coordinated pair of times covers both, each on its own day", () => {
  const text = "(23:55 and 01:28 UTC)";
  expect(dateTimes(text, postedAt)).toEqual(["2026-10-24T23:55:00.000Z", "2026-10-25T01:28:00.000Z"]);
  expect(sources(text)).toEqual(["23:55", "01:28 UTC"]);
});

test("a zone after a longer list covers every time, stepping back a day at each wrap", () => {
  expect(dateTimes("23:55, 00:10 and 01:28 UTC", postedAt)).toEqual([
    "2026-10-24T23:55:00.000Z",
    "2026-10-25T00:10:00.000Z",
    "2026-10-25T01:28:00.000Z",
  ]);
  expect(dateTimes("22:00, 23:55 or 01:28Z", postedAt)).toEqual([
    "2026-10-24T22:00:00.000Z",
    "2026-10-24T23:55:00.000Z",
    "2026-10-25T01:28:00.000Z",
  ]);
});

test("a range and a between phrase share the zone", () => {
  expect(dateTimes("23:55–01:28 UTC", postedAt)).toEqual(["2026-10-24T23:55:00.000Z", "2026-10-25T01:28:00.000Z"]);
  expect(dateTimes("23:55-01:28 UTC", postedAt)).toEqual(["2026-10-24T23:55:00.000Z", "2026-10-25T01:28:00.000Z"]);
  expect(dateTimes("between 23:55 and 01:28 UTC", postedAt)).toEqual([
    "2026-10-24T23:55:00.000Z",
    "2026-10-25T01:28:00.000Z",
  ]);
  expect(sources("between 23:55 and 01:28 UTC.")).toEqual(["23:55", "01:28 UTC"]);
});

test("times in the same day need no day step", () => {
  expect(dateTimes("00:10 and 01:28 UTC", postedAt)).toEqual(["2026-10-25T00:10:00.000Z", "2026-10-25T01:28:00.000Z"]);
});

test("times without a shared zone, and versions, ratios and scores, stay plain", () => {
  for (const text of [
    "23:55 and 01:28",
    "23:55 and 01:28 PST",
    "a 16:9 screen",
    "the ratio 16:9 and 4:3 UTC",
    "won 12:10 in 2.1.14:30 UTC",
    "score 24:17 and 31:28",
    "v1.2:30 and 3:45",
    "the 23:55 and 01:28 meeting",
  ]) {
    expect(dateTimes(text)).toEqual([]);
  }
});

test("a single time with a zone, and times in code, behave as before", () => {
  expect(sources("at 01:28 UTC and 23:55")).toEqual(["01:28 UTC"]);
  expect(sources("`23:55 and 01:28 UTC` stays code")).toEqual([]);
});

test("a very long run of times without a zone scans in linear time", () => {
  const started = performance.now();
  expect(dateTimes("00:00, ".repeat(60_000))).toEqual([]);
  expect(performance.now() - started).toBeLessThan(5000);
  expect(dateTimes("00:00, ".repeat(500) + "01:00 UTC").length).toBe(501);
});

test("an ISO timestamp beside a zoned clock time keeps its own hover and is not read as a list", () => {
  expect(dateTimes("2026-10-24T05:21-07:00 and 08:00 UTC", postedAt)).toEqual([
    "2026-10-24T12:21:00.000Z",
    "2026-10-24T08:00:00.000Z",
  ]);
  expect(sources("2026-10-24T05:21-07:00 and 08:00 UTC")).toEqual(["2026-10-24T05:21-07:00", "08:00 UTC"]);
});
