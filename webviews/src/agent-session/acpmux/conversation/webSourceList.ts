// The pages a web search or fetch call read, for its sources chip (WebSources.tsx). Claude Code's
// WebSearch result opens with `Links: [{"title": ..., "url": ...}, ...]` on one line, before the
// summary its search model wrote; a WebFetch reads the one page its title names ("Fetch <url>").
// The doc that ranked this (leo-workspace research/2026-11-05-where-we-stand.md, "Rendering"):
// web search and fetch drew as a generic row in every harness.
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type WebSource = { title: string; url: string; host: string };

/// The most sources the chip lists; a search returns about ten.
const MAX_SOURCES = 20;
const LINKS = /^Links:\s*(\[.*\])\s*$/m;
const FETCH = /^Fetch\s+(https?:\/\/\S+)\s*$/;

const hostOf = (url: string): string | undefined => {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" || parsed.protocol === "http:"
      ? parsed.hostname.replace(/^www\./, "")
      : undefined;
  } catch {
    return undefined;
  }
};

const read = new WeakMap<Tool, WebSource[]>();

/// A finished `fetch` call's sources, in the order the harness gave them, each http(s) link once.
/// Empty for any other call, a running one, or a result without links.
export function webSources(tool: Tool | undefined): WebSource[] {
  if (!tool || tool.kind !== "fetch" || tool.status !== "completed") return [];
  const kept = read.get(tool);
  if (kept) return kept;
  const found: WebSource[] = [];
  const add = (title: unknown, url: unknown) => {
    if (typeof url !== "string" || found.length >= MAX_SOURCES || found.some((source) => source.url === url)) return;
    const host = hostOf(url);
    if (host) found.push({ title: typeof title === "string" && title.trim() ? title.trim() : host, url, host });
  };
  const links = tool.output ? LINKS.exec(tool.output)?.[1] : undefined;
  if (links) {
    try {
      const list: unknown = JSON.parse(links);
      if (Array.isArray(list))
        for (const link of list)
          if (link && typeof link === "object")
            add((link as { title?: unknown }).title, (link as { url?: unknown }).url);
    } catch {
      // Not the harness's list: the call keeps its plain row.
    }
  } else {
    const url = FETCH.exec(tool.title.trim())?.[1];
    if (url) add(undefined, url);
  }
  read.set(tool, found);
  return found;
}

/// The call's output without its links line, which the chip lists instead.
export function withoutLinks(output: string): string {
  return output.replace(LINKS, "").replace(/\n{3,}/g, "\n\n");
}

/// The closed chip's line: the first `count` sites by name, and how many pages that leaves out
/// ("+N"): every page past the one each named site stands for, so a second page from a named site
/// counts too, and the number always matches the list the chip opens to.
export function sourcesLine(sources: readonly WebSource[], count: number): { named: string[]; more: number } {
  const named = [...new Set(sources.map((source) => source.host))].slice(0, count);
  return { named, more: sources.length - named.length };
}
