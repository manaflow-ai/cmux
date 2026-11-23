// GitHub's rendering of a body, drawn from the page's allowlist (Leo, 2026-11-07: "is it possible
// to, like, just add the rendering for the links or whatever? Some of this is quite weird"):
// cmux#37993's bot comments showed their <a><picture>, <details>, <dl> and <sup> as text.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { GitHubMarkdown } from "./GitHubMarkdown";
import { githubHTML, imageSource } from "./githubHTML";
import { mockBotBodyHTML, mockBotReviewCommentHTML } from "./mockBotComments";

const scope = globalThis as { DOMParser?: unknown };
const had = scope.DOMParser;
beforeAll(() => {
  scope.DOMParser = new JSDOM("").window.DOMParser;
});
afterAll(() => {
  scope.DOMParser = had;
});

const open = () => {};
const draw = (html: string) => renderToStaticMarkup(<GitHubMarkdown source="raw" html={html} open={open} />);

test("a bot's footer badge is its picture, light and dark, and its <sup> line is small text", () => {
  const out = draw(mockBotBodyHTML);
  expect(out).not.toContain("&lt;picture");
  expect(out).not.toContain("&lt;sup");
  expect(out).toMatch(/<a class="gh-md-link" href="https:\/\/backend\.blacksmith\.sh\/[^"]*"[^>]*><picture>/);
  expect(out).toContain('<source media="(prefers-color-scheme: dark)" srcSet="data:image/svg+xml;base64,');
  expect(out).toContain('<source media="(prefers-color-scheme: light)" srcSet="data:image/svg+xml;base64,');
  expect(out).toMatch(
    /<img class="gh-md-img" src="data:image\/svg\+xml;base64,[^"]+" alt="Autofix with \[code\]smith" width="190" height="28"/,
  );
  expect(out).toContain('<sup><a class="gh-md-link" href="https://app.blacksmith.sh/');
  expect(out).toContain("<code>@codesmith-bot</code>");
  // The check table keeps its alignment as a style, not an attribute.
  expect(out).toContain('<th style="text-align:center">Status</th>');
  // A heading's own anchor and its icon are github.com chrome.
  expect(out).not.toContain("Permalink");
  expect(out).not.toContain("<svg");
  expect(out).toContain("<h4>Pre-merge checks</h4>");
  // The script is gone, text and all; an image off GitHub's proxy never loads.
  expect(out).not.toContain("document.title");
  expect(out).not.toContain("tracker.example");
});

test("a review's prompt folds in <details> with its summary, and <dl><dd> holds its code", () => {
  const out = draw(mockBotReviewCommentHTML);
  expect(out).not.toContain("&lt;details");
  expect(out).not.toContain("&lt;dd");
  expect(out).toMatch(/<details><summary><picture>.*<\/picture> Prompt for AI Agents<\/summary>/s);
  expect(out).toContain("<dl><dd>");
  expect(out).toContain("<pre><code>Treat finding text");
  // Folded at first: no `open`.
  expect(out).not.toMatch(/<details open/);
});

test("only the allowlist survives: no handler, style, class, id, form, frame or unsafe link", () => {
  const out = draw(
    [
      `<p id="x" class="y" style="color:red" onclick="alert(1)">Hi <a href="javascript:alert(1)">bad</a> <a href="https://github.com/a">ok</a></p>`,
      `<img src="https://camo.githubusercontent.com/abc" onerror="alert(1)" alt="shot" width="99999">`,
      `<img src="http://camo.githubusercontent.com/abc" alt="plain http">`,
      `<iframe src="https://evil.example"></iframe><form action="https://evil.example"><input name="q"></form>`,
      `<details open><summary>More</summary><p>inside</p></details>`,
      `<ul class="contains-task-list"><li class="task-list-item"><input type="checkbox" disabled checked> done</li><li class="task-list-item"><input type="checkbox" disabled> open</li></ul>`,
      `<p><kbd>⌘</kbd><sub>low</sub><g-emoji alias="robot">🤖</g-emoji></p>`,
    ].join(""),
  );
  expect(out).not.toMatch(/\b(id|class|style|onclick|onerror)="(x|y|color:red|alert\(1\))"/);
  expect(out).not.toContain("javascript:");
  expect(out).toContain("bad");
  expect(out).toContain('<a class="gh-md-link" href="https://github.com/a"');
  expect(out).toContain(
    '<img class="gh-md-img" src="https://camo.githubusercontent.com/abc" alt="shot" loading="lazy"',
  );
  expect(out).not.toContain('width="99999"');
  expect(out).not.toContain("http://camo");
  expect(out).toContain("plain http");
  expect(out).not.toContain("<iframe");
  expect(out).not.toContain("<form");
  expect(out).not.toContain("<input");
  expect(out).toContain("<details><summary>More</summary>");
  expect(out).toContain('<li data-task="done"><span class="gh-md-task" aria-hidden="true"></span> done</li>');
  expect(out).toContain('<li data-task="open">');
  expect(out).toContain("<kbd>⌘</kbd><sub>low</sub>🤖");
});

test("images load from GitHub's proxy and attachment hosts or inline, nowhere else", () => {
  expect(imageSource("https://camo.githubusercontent.com/a/b")).toBe("https://camo.githubusercontent.com/a/b");
  expect(imageSource("https://private-user-images.githubusercontent.com/1.png?jwt=x")).toBeDefined();
  expect(imageSource("https://storage.googleapis.com/x.svg")).toBeUndefined();
  expect(imageSource("https://user:pw@camo.githubusercontent.com/a")).toBeUndefined();
  expect(imageSource("https://camo.githubusercontent.com.evil.example/a")).toBeUndefined();
  expect(imageSource("data:image/png;base64,AAAA")).toBe("data:image/png;base64,AAAA");
  expect(imageSource("data:text/html,<script>")).toBeUndefined();
});

test("with no HTML, or nowhere to parse it, the Markdown draws as before", () => {
  expect(renderToStaticMarkup(<GitHubMarkdown source="**hi**" open={open} />)).toBe(
    '<div class="gh-md"><p><strong>hi</strong></p></div>',
  );
  scope.DOMParser = undefined;
  try {
    expect(githubHTML("<p>x</p>", open)).toBeNull();
    expect(renderToStaticMarkup(<GitHubMarkdown source="**hi**" html="<p>x</p>" open={open} />)).toContain(
      "<strong>hi</strong>",
    );
  } finally {
    scope.DOMParser = new JSDOM("").window.DOMParser;
  }
});

test("thousands of nested tags draw their text, not a stack overflow", () => {
  const depth = 5000;
  const out = draw(`${"<div>".repeat(depth)}deep${"</div>".repeat(depth)}<p>after</p>`);
  expect(out).toContain("deep");
  expect(out).toContain("<p>after</p>");
  expect(out.split("<div>").length - 1).toBeLessThanOrEqual(50);
});

// Review of #38075, F2: an ordinary <img> keeps its validated srcset (GitHub's responsive images),
// and one with only a srcset loads its first candidate instead of falling back to alt text.
test("an image keeps its srcset when every candidate may load, and a srcset alone still draws", () => {
  const a = "https://private-user-images.githubusercontent.com/1/a.png";
  const b = "https://private-user-images.githubusercontent.com/1/b.png";
  const both = draw(`<p><img src="${a}" srcset="${a} 1x, ${b} 2x" alt="shot"></p>`);
  expect(both).toContain(`src="${a}"`);
  expect(both).toContain(`srcSet="${a} 1x, ${b} 2x"`);
  const only = draw(`<p><img srcset="${a} 640w, ${b} 1280w" alt="shot"></p>`);
  expect(only).toContain(`<img class="gh-md-img" src="${a}"`);
  expect(only).toContain(`srcSet="${a} 640w, ${b} 1280w"`);
  // One candidate off GitHub's hosts drops the whole srcset; the src still loads.
  const mixed = draw(`<p><img src="${a}" srcset="${a} 1x, https://evil.example/x.png 2x" alt="shot"></p>`);
  expect(mixed).toContain(`src="${a}"`);
  expect(mixed).not.toContain("srcSet");
  expect(mixed).not.toContain("evil.example");
});
