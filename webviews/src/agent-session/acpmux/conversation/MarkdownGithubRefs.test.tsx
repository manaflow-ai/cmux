// A GitHub reference in a reply's prose is the pull request chip, whatever form names it (Leo
// 2026-11-07, on "Relay deploy (subrouter-internal#54):": "should we auto-render this as a link?").
// A code span, a code block, a link's label and a URL keep theirs as written.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";

const hrefs = (markdown: string) =>
  [...renderToStaticMarkup(<Markdown>{markdown}</Markdown>).matchAll(/<a\b[^>]*href="([^"]+)"/g)].map(
    (match) => match[1]!,
  );

test("a known repository's short name is its pull request chip", () => {
  const html = renderToStaticMarkup(<Markdown>{"- Relay deploy (cmux#54):"}</Markdown>);
  expect(html).toContain('href="https://github.com/manaflow-ai/cmux/pull/54"');
  expect(html).toContain('<span class="cv-chip__label">cmux#54</span>');
  expect(html).toContain("cv-chip__icon--gh");
});

test("every form links: owner/repo#N and cmux's short name", () => {
  expect(hrefs("acme/widgets#9 and cmux#37758")).toEqual([
    "https://github.com/acme/widgets/pull/9",
    "https://github.com/manaflow-ai/cmux/pull/37758",
  ]);
});

// No team's own repositories are known names: a person's lw#12 or hq#4879 is theirs (Leo
// 2026-11-26: "identify all the weird opinoinated fleet things we shipped into the app and remove
// them").
test("a team's short names stay text", () => {
  expect(hrefs("lw#12, hq#4879, subrouter-internal#54 and leo-workspace#843")).toEqual([]);
});

test("code, a link's label and a URL keep a reference as written", () => {
  expect(hrefs("`cmux#1`\n\n```\nsubrouter-internal#2\n```")).toEqual([]);
  expect(hrefs("[about cmux#3](https://example.com/a)")).toEqual(["https://example.com/a"]);
  expect(hrefs("open https://example.com/?repo=hq#4 now")).toEqual(["https://example.com/?repo=hq#4"]);
});

test("look-alikes stay text", () => {
  expect(hrefs("C# and F#7, color #123456, issue #1 of 3, foo#12, subrouter-external#5")).toEqual([]);
});
