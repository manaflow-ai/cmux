import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

/** What the agent is working on, for a terminal or browser tab opened from its chat (#16620). */
export type PaneContext = { cwd?: string; urls: string[] };

const URL_PATTERN = /\bhttps?:\/\/[^\s<>"'`()[\]{}]+/g;
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "0.0.0.0", "[::1]"]);

/** A local dev server. `0.0.0.0` (a bind address) becomes `localhost`, which a browser can open. */
function devServer(url: URL): URL | undefined {
  const host = url.hostname.toLowerCase();
  if (!LOCAL_HOSTS.has(host) && !host.endsWith(".localhost")) return undefined;
  if (host === "0.0.0.0") url.hostname = "localhost";
  return url;
}

const isPullRequest = (url: URL) =>
  /^(www\.)?github\.com$/i.test(url.hostname) && /^\/[^/]+\/[^/]+\/pull\/\d+/.test(url.pathname);

function rowTexts(row: AcpmuxRow): string[] {
  const texts = row.text ? [row.text] : [];
  for (const item of row.items ?? []) texts.push(item.text, item.tool?.inputSummary ?? "", item.tool?.output ?? "");
  return texts;
}

/**
 * The transcript's dev servers, then its pull request links, each newest first, at most
 * `limit`. Other URLs are left out: a browser tab opened from the chat loads one of these
 * or nothing. Trailing sentence punctuation is not part of a URL.
 */
export function workingURLs(rows: AcpmuxRow[], limit = 20): string[] {
  const found: { url: string; rank: number }[] = [];
  const seen = new Set<string>();
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const texts = rowTexts(rows[index]!);
    for (let t = texts.length - 1; t >= 0; t -= 1) {
      const matches = [...(texts[t]!.match(URL_PATTERN) ?? [])].reverse();
      for (const raw of matches) {
        let url: URL;
        try {
          url = new URL(raw.replace(/[.,;:!?]+$/, ""));
        } catch {
          continue;
        }
        const rank = devServer(url) ? 0 : isPullRequest(url) ? 1 : undefined;
        const text = url.toString();
        if (rank === undefined || seen.has(text)) continue;
        seen.add(text);
        found.push({ url: text, rank });
      }
    }
  }
  // Ranked over the whole transcript, so 20 newer doc links never hide the dev server.
  return found
    .sort((a, b) => a.rank - b.rank)
    .map((entry) => entry.url)
    .slice(0, limit);
}

/** The selected session's cwd and the transcript's working URLs. */
export function paneContext(snapshot: Pick<AcpmuxSnapshot, "rows" | "sessions" | "sessionId">): PaneContext {
  const cwd = snapshot.sessions.find((session) => session.sessionId === snapshot.sessionId)?.cwd;
  return { ...(cwd ? { cwd } : {}), urls: workingURLs(snapshot.rows) };
}
