// l10n-allow-file: test fixture tool results, not shipped UI.
// A web search or fetch call's sources (webSourceList.ts) for its chip (WebSources.tsx). Before: the
// call drew as a generic row, its links a line of JSON inside the opened result.
import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { fetchedPage, pagePathLabel, sourcesLine, webSources, withoutLinks } from "./webSourceList";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const tool = (extra: Partial<Tool>): Tool =>
  ({ id: "t", title: "Search x", kind: "fetch", status: "completed", ...extra }) as Tool;

// Claude Code's WebSearch result, as acpmux records it (a session of 2026-11-05).
const SEARCH = [
  'Web search results for query: "T3 Code desktop app"',
  "",
  'Links: [{"title":"GitHub - pingdotgg/t3code","url":"https://github.com/pingdotgg/t3code"},{"title":"github.com","url":"https://www.github.com/pub-forks/t3code"},{"title":"","url":"https://repowise.dev/repo/pingdotgg/t3code"},{"title":"dup","url":"https://github.com/pingdotgg/t3code"},{"title":"bad","url":"javascript:alert(1)"}]',
  "",
  "T3 Code is built around an Electron desktop app.",
].join("\n");

describe("webSources", () => {
  test("a search's links, each once, http(s) only, a missing title read as its site", () => {
    expect(webSources(tool({ output: SEARCH }))).toEqual([
      { title: "GitHub - pingdotgg/t3code", url: "https://github.com/pingdotgg/t3code", host: "github.com" },
      { title: "github.com", url: "https://www.github.com/pub-forks/t3code", host: "github.com" },
      { title: "repowise.dev", url: "https://repowise.dev/repo/pingdotgg/t3code", host: "repowise.dev" },
    ]);
  });

  // Codex review of #36386 at c943edb1, F1: a link with a user name or password is a phishing
  // shape, never a source (replyHref.ts safeHref).
  test("a link with credentials in it is no source", () => {
    const links =
      'Links: [{"title":"Bank","url":"https://bank.example@evil.example/login"},{"title":"x","url":"https://u:p@example.com/"},{"title":"Ok","url":"https://example.com/a"}]';
    expect(webSources(tool({ output: links })).map((source) => source.url)).toEqual(["https://example.com/a"]);
    expect(webSources(tool({ title: "Fetch https://u:p@example.com/", output: "page" }))).toEqual([]);
  });

  test("a fetch is the page its title names", () => {
    expect(webSources(tool({ title: "Fetch https://example.com/docs", output: "# Docs" }))).toEqual([
      { title: "example.com", url: "https://example.com/docs", host: "example.com" },
    ]);
  });

  test("no chip for a running call, another kind, or a result without links", () => {
    expect(webSources(tool({ output: SEARCH, status: "in_progress" }))).toEqual([]);
    expect(webSources(tool({ output: SEARCH, kind: "read" }))).toEqual([]);
    expect(webSources(tool({ output: "Links: [not json]" }))).toEqual([]);
    expect(webSources(undefined)).toEqual([]);
  });

  test("the opened result drops the links line the chip lists", () => {
    expect(withoutLinks(tool({ output: SEARCH }), SEARCH)).toBe(
      'Web search results for query: "T3 Code desktop app"\n\nT3 Code is built around an Electron desktop app.',
    );
  });

  // Codex review of #36386, F1: a fetched page's own `Links: [...]` line is the page's text.
  test("a fetched page keeps a Links line of its own, and its chip is the page it fetched", () => {
    const page = 'Links: [{"title":"Elsewhere","url":"https://elsewhere.example/"}]\nThe page.';
    const fetch = tool({ title: "Fetch https://example.com/docs", output: page });
    expect(webSources(fetch).map((source) => source.url)).toEqual(["https://example.com/docs"]);
    expect(withoutLinks(fetch, page)).toBe(page);
  });

  test("a call without sources keeps its output whole", () => {
    expect(withoutLinks(tool({ output: "Links: [not json]" }), "Links: [not json]")).toBe("Links: [not json]");
  });
});

describe("sourcesLine", () => {
  test("+N counts every page the named sites leave out, a named site's second page too", () => {
    // Two GitHub pages and one repowise page: both sites named, one page left for "+1".
    expect(sourcesLine(webSources(tool({ output: SEARCH })), 3)).toEqual({
      named: ["github.com", "repowise.dev"],
      more: 1,
    });
    const pages = ["a.com", "b.com", "c.com", "d.com", "a.com"].map((host, at) => ({
      title: host,
      url: `https://${host}/${at}`,
      host,
    }));
    expect(sourcesLine(pages, 3)).toEqual({ named: ["a.com", "b.com", "c.com"], more: 2 });
    expect(sourcesLine([], 3)).toEqual({ named: [], more: 0 });
  });
});

describe("fetchedPage", () => {
  test("a finished fetch is its one page; a search, a running fetch or a bad link has none", () => {
    expect(fetchedPage(tool({ title: "Fetch https://www.example.com/docs/a", output: "page" }))).toEqual({
      title: "example.com",
      url: "https://www.example.com/docs/a",
      host: "example.com",
    });
    expect(fetchedPage(tool({ output: SEARCH }))).toBeUndefined();
    expect(fetchedPage(tool({ title: "Fetch https://example.com/", status: "in_progress" }))).toBeUndefined();
    expect(fetchedPage(tool({ title: "Fetch javascript:alert(1)" }))).toBeUndefined();
    expect(fetchedPage(tool({ title: "Fetch https://example.com/", kind: "read" }))).toBeUndefined();
    expect(fetchedPage(undefined)).toBeUndefined();
  });
});

describe("pagePathLabel", () => {
  test("the path's last two segments, decoded, without a page extension", () => {
    expect(pagePathLabel("https://docs.example.com/en/docs/claude-code/hooks")).toBe("claude-code/hooks");
    expect(pagePathLabel("https://example.com/guide/")).toBe("guide");
    expect(pagePathLabel("https://example.com/a/b/Getting%20Started.html?x=1#top")).toBe("b/Getting Started");
  });

  test("a front page or a link that does not parse has no label", () => {
    expect(pagePathLabel("https://example.com/")).toBe("");
    expect(pagePathLabel("https://example.com")).toBe("");
    expect(pagePathLabel("not a url")).toBe("");
  });

  test("a bad escape stays as written and a long path is cut", () => {
    expect(pagePathLabel("https://example.com/%E0%A4%A")).toBe("%E0%A4%A");
    const label = pagePathLabel(`https://example.com/${"x".repeat(80)}`);
    expect(label.length).toBe(48);
    expect(label.endsWith("…")).toBe(true);
  });
});
