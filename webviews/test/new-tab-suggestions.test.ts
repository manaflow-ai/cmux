// Leo 10-13 (photo, "red" typed in New Tab): two near-duplicate Reddit rows, one of them a long
// `?solution=…` challenge address; an open tab on that same address ("workspace-1 ·
// reddit.com/?solution=…") listed again under them; odd ordering. Now the rows dedupe by the
// canonical address (tracking and token noise stripped), the open tab wins as "Switch to tab",
// titles are clean and details short, and the order is Chrome's and Arc's: the top hit, open tabs,
// visited pages, the web search, Ask. The list is capped.
import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import {
  canonicalAddress,
  cleanTitle,
  MAX_SUGGESTIONS,
  screenRows,
  type ScreenRow,
} from "../src/agent-session/acpmux/newtab/screenModel";

const TOKEN = "eb7139b868b8d71eeb7139b868b8d71e";
const CHALLENGE = `https://www.reddit.com/?solution=${TOKEN}&js_challenge=1&token=${TOKEN}a91f`;
const ask = { harness: "claude", agent: "Claude Code", model: "Claude Opus 5.5" };

const context = (fields: Partial<OmnibarContext>) => ({ omnibar: { ...EMPTY_OMNIBAR, ...fields }, ask });
const photo = context({
  tabs: [
    {
      id: "reddit-tab",
      kind: "browser",
      title: "Reddit - The heart of the internet",
      detail: CHALLENGE.replace(/^https:\/\/www\./, ""),
      workspace: "workspace-1",
    },
    { id: "redis-tab", kind: "browser", title: "Redis docs", detail: "redis.io/docs", workspace: "notes" },
  ],
  history: [
    { url: CHALLENGE, title: "Reddit - The heart of the internet" },
    { url: "https://www.reddit.com/", title: "Reddit" },
    { url: "https://www.redblobgames.com/", title: "Red Blob Games" },
  ],
});

const address = (row: ScreenRow) =>
  row.type === "open" || row.type === "history" ? canonicalAddress(row.url) : row.type === "tab" ? row.url : undefined;

test('"red" shows Reddit once, as the open tab, with a clean title and a short host', () => {
  const rows = screenRows("red", photo);
  const reddit = rows.filter((row) => address(row) === "reddit.com");
  expect(reddit).toEqual([
    { type: "tab", id: "reddit-tab", title: "Reddit", detail: "reddit.com", url: "reddit.com" },
  ]);
  for (const row of rows) {
    const detail = "detail" in row ? row.detail : undefined;
    expect(detail ?? "").not.toContain("solution");
  }
});

test("the order is the top hit, open tabs, visited pages, the web search, then Ask", () => {
  const rows = screenRows("red", photo);
  expect(rows.map((row) => [row.type, "id" in row ? row.id : "url" in row ? canonicalAddress(row.url) : ""])).toEqual([
    ["tab", "reddit-tab"],
    ["tab", "redis-tab"],
    ["history", "redblobgames.com"],
    ["search", ""],
    ["ask", ""],
  ]);
});

test("a typed address an open tab already shows switches to that tab", () => {
  const rows = screenRows("reddit.com", photo);
  expect(rows[0]).toMatchObject({ type: "tab", id: "reddit-tab" });
  expect(rows.filter((row) => address(row) === "reddit.com")).toHaveLength(1);
  expect(rows.at(-1)?.type).toBe("ask");
});

test("the rows are capped, and the web search and Ask always stay", () => {
  const many = context({
    history: Array.from({ length: 30 }, (_, index) => ({
      url: `https://red${index}.example.com/`,
      title: `Red page ${index}`,
    })),
  });
  const rows = screenRows("red", many);
  expect(rows.length).toBe(MAX_SUGGESTIONS);
  expect(rows.slice(-2).map((row) => row.type)).toEqual(["search", "ask"]);
});

test("the canonical address drops tracking and token parameters and keeps the ones that name the page", () => {
  expect(canonicalAddress(CHALLENGE)).toBe("reddit.com");
  expect(canonicalAddress("https://www.google.com/search?q=cats&utm_source=chrome&gclid=abc")).toBe(
    "google.com/search?q=cats",
  );
  expect(canonicalAddress("https://youtube.com/watch?v=dQw4w9WgXcQ&si=Xk2_aZ9-bq81pLmN")).toBe(
    "youtube.com/watch?v=dQw4w9WgXcQ",
  );
  expect(canonicalAddress("http://Example.com/a/b/#top")).toBe("example.com/a/b");
});

test("a title loses the site's tagline and its trailing site name", () => {
  expect(cleanTitle("Reddit - The heart of the internet", "https://www.reddit.com/")).toBe("Reddit");
  expect(cleanTitle("Borrowing in loops : r/rust - Reddit", "https://www.reddit.com/r/rust/x")).toBe(
    "Borrowing in loops : r/rust",
  );
  expect(cleanTitle("GitHub · Build and ship software", "https://github.com/")).toBe("GitHub");
  expect(cleanTitle("Vite - Next Generation Frontend Tooling", "https://vite.dev/guide")).toBe("Vite");
  expect(cleanTitle("A plain title", "https://example.com/")).toBe("A plain title");
});
