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
