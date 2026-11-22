// A reply's data URL images share one budget (8 MB of URL text) besides the 2 MB cap of each:
// the images after the budget draw as their name only, so a reply of many images cannot make the
// pane decode and hold an unbounded amount.
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown, MAX_DATA_URL_LENGTH } from "../conversation/Markdown";

const image = (index: number) => `data:image/png;base64,${String(index).padEnd(MAX_DATA_URL_LENGTH - 30, "A")}`;

test("five images under 2 MB each: the four within 8 MB draw, the fifth draws as its name", () => {
  const source = [1, 2, 3, 4, 5].map((index) => `![shot ${index}](${image(index)})`).join("\n\n");
  const html = renderToStaticMarkup(createElement(Markdown, null, source));
  expect(html.match(/<img class="cv-img"/g)?.length).toBe(4);
  expect(html).toContain("shot 5");
  expect(html).not.toContain(image(5).slice(0, 40));
});

test("a reply under the budget draws every image", () => {
  const source = [1, 2].map((index) => `![shot ${index}](${image(index)})`).join(" ");
  const html = renderToStaticMarkup(createElement(Markdown, null, source));
  expect(html.match(/<img class="cv-img"/g)?.length).toBe(2);
});
