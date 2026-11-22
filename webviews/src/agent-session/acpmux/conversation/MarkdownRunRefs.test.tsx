// A nightly build and an Actions run in a reply link to the run, drawn as the pull request chip is
// (Leo 2026-11-10, of "build 4270949510401," as plain text: "should these be linked too?"). Code
// and a link's label keep them as written.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";

const RUN = "https://github.com/manaflow-ai/cmux/actions/runs/42709495104";
const hrefs = (markdown: string, githubRepository?: string) =>
  [
    ...renderToStaticMarkup(<Markdown githubRepository={githubRepository}>{markdown}</Markdown>).matchAll(
      /<a\b[^>]*href="([^"]+)"/g,
    ),
  ].map((match) => match[1]!);

test("the screenshot's build number is a reference chip to its run", () => {
  const html = renderToStaticMarkup(
    <Markdown>{"Leo's flow is green on build 4270949510401, the nightly he has."}</Markdown>,
  );
  expect(html).toContain(`href="${RUN}"`);
  expect(html).toMatch(/class="cv-link cv-chip is-web is-ref"[^>]*>.*?cv-link__icon--gh/);
  expect(html).toContain('<span class="cv-chip__label">4270949510401</span>');
  // The word stays prose; only the number is the link.
  expect(html).toContain("on build <a");
});

test("a run in the chat's repository links", () => {
  expect(hrefs("Shard 3 failed in run 42709495104.", "manaflow-ai/cmux")).toEqual([RUN]);
});

test("code, a code block and a link's label keep a build as written", () => {
  expect(hrefs("`build 4270949510401`\n\n```\nbuild 4270949510401\n```")).toEqual([]);
  expect(hrefs("[build 4270949510401](https://example.com/a)")).toEqual(["https://example.com/a"]);
});

test("look-alikes stay text", () => {
  expect(hrefs("build 2026, run 3 tests, 4270949510401 alone, call 555-123-4567", "manaflow-ai/cmux")).toEqual([]);
});
