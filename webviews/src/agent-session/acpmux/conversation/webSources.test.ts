// l10n-allow-file: test fixture tool results, not shipped UI.
// A web search or fetch call's sources (webSources.ts) for its chip (WebSources.tsx). Before: the
// call drew as a generic row, its links a line of JSON inside the opened result.
import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { webSources, withoutLinks } from "./webSources";

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
    expect(withoutLinks(SEARCH)).toBe(
      'Web search results for query: "T3 Code desktop app"\n\nT3 Code is built around an Electron desktop app.',
    );
  });
});
