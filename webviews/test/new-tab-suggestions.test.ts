// Leo 10-13 (photo, "red" typed in New Tab): two near-duplicate Reddit rows, one of them a long
// `?solution=…` challenge address; an open tab on that same address ("workspace-1 ·
// reddit.com/?solution=…") listed again under them; odd ordering. Now the rows dedupe by the
// canonical address (tracking and token noise stripped), the open tab wins as "Switch to tab",
// titles are clean and details short. Leo 2026-10-24 ("Search the web. Do you really want that
// first?"): Ask leads (an address or an exact name above it), then open tabs, visited pages, and
// the web search last. The list is capped.
import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import {
  canonicalAddress,
  cleanTitle,
  MAX_MATCH_ROWS,
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
  expect(reddit).toEqual([{ type: "tab", id: "reddit-tab", title: "Reddit", detail: "reddit.com", url: "reddit.com" }]);
  for (const row of rows) {
    const detail = "detail" in row ? row.detail : undefined;
    expect(detail ?? "").not.toContain("solution");
  }
});

test("the order is Ask, open tabs, visited pages, then the web search", () => {
  const rows = screenRows("red", photo);
  expect(rows.map((row) => [row.type, "id" in row ? row.id : "url" in row ? canonicalAddress(row.url) : ""])).toEqual([
    ["ask", ""],
    ["tab", "reddit-tab"],
    ["tab", "redis-tab"],
    ["history", "redblobgames.com"],
    ["search", ""],
  ]);
});

test("a typed address an open tab already shows switches to that tab", () => {
  const rows = screenRows("reddit.com", photo);
  expect(rows[0]).toMatchObject({ type: "tab", id: "reddit-tab" });
  expect(rows.filter((row) => address(row) === "reddit.com")).toHaveLength(1);
  expect(rows[1]?.type).toBe("ask");
  expect(rows.at(-1)?.type).toBe("search");
});

test("the matches are capped, and Ask and the web search always stay", () => {
  const many = context({
    history: Array.from({ length: 30 }, (_, index) => ({
      url: `https://red${index}.example.com/`,
      title: `Red page ${index}`,
    })),
  });
  const rows = screenRows("red", many);
  expect(rows.length).toBe(MAX_MATCH_ROWS + 2);
  expect(rows[0]?.type).toBe("ask");
  expect(rows.at(-1)?.type).toBe("search");
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
  expect(cleanTitle("Vite - Next Generation Frontend Tooling", "https://vite.dev/")).toBe("Vite");
  // Off the site's front page, "Site - page" names the page: it stays.
  expect(cleanTitle("GitHub - manaflow-ai/cmux: Terminal for agents", "https://github.com/manaflow-ai/cmux")).toBe(
    "GitHub - manaflow-ai/cmux: Terminal for agents",
  );
  expect(cleanTitle("A plain title", "https://example.com/")).toBe("A plain title");
});

test("parameters that name a page keep it apart from its neighbours", () => {
  const kept = [
    "https://drive.google.com/open?id=1aB2cD3eF4gH5iJ6kL7mN8oP9qR0sT",
    "https://www.youtube.com/playlist?list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG",
    "https://github.com/manaflow-ai/cmux/commit?sha=3f786850e387550fdab836ed7e6dc881de23001b",
    "https://example.com/items?page_token=CAESBggDEAEYAQ2a9f8c7d6e5",
    "https://github.com/manaflow-ai/cmux/tree?ref=feat-cmux-next",
  ];
  for (const url of kept) expect(canonicalAddress(url)).toBe(url.replace("https://", "").replace("www.", ""));
});

test("a typed link to another file never switches to the open tab on a different one", () => {
  const drive = context({
    tabs: [
      {
        id: "file-a",
        kind: "browser",
        title: "Plan - Google Drive",
        detail: "drive.google.com/open?id=1aB2cD3eF4gH5iJ6kL7mN8oP9qR0sTA",
      },
    ],
  });
  const rows = screenRows("https://drive.google.com/open?id=9zY8xW7vU6tS5rQ4pO3nM2lK1jI0hGB", drive);
  expect(rows[0]).toMatchObject({ type: "open" });
});

test("a page that is not on the web shows its path, not its scheme", () => {
  const rows = screenRows(
    "notes",
    context({ tabs: [{ id: "f", kind: "browser", title: "Release notes", detail: "file:///Users/you/notes.html" }] }),
  );
  expect(rows.find((row) => row.type === "tab")).toMatchObject({ detail: "/Users/you/notes.html" });
});

// Capture of PR 24991: a workspace's terminal tabs are titled "~" and list under the workspace's
// name. Typing that name exactly leads with its tab, Ask right under it.
test("a workspace's exact name leads with its tab, Ask second, the web search last", () => {
  const rows = screenRows(
    "app-efficiency",
    context({
      tabs: [
        { id: "t-eff", kind: "terminal", title: "~", detail: "/Users/you", workspace: "app-efficiency" },
        { id: "t-tool", kind: "terminal", title: "~", detail: "/Users/you", workspace: "toolbar-diffviewer" },
      ],
    }),
  );
  expect(rows.slice(0, 2).map((row) => [row.type, "id" in row ? row.id : ""])).toEqual([
    ["tab", "t-eff"],
    ["ask", ""],
  ]);
  expect(rows.at(-1)?.type).toBe("search");
  // "app" alone is no exact name: Ask leads.
  expect(
    screenRows("app", context({ tabs: [{ id: "t", kind: "terminal", title: "~", workspace: "app-efficiency" }] }))[0]
      ?.type,
  ).toBe("ask");
});

test("a workspace row named exactly leads over the tabs in it", () => {
  const rows = screenRows(
    "app-efficiency",
    context({
      tabs: [
        { id: "t-1", kind: "terminal", title: "~", workspace: "app-efficiency" },
        { id: "t-2", kind: "terminal", title: "~", workspace: "app-efficiency" },
      ],
      workspaces: [{ id: "ws-eff", name: "app-efficiency" }],
    }),
  );
  expect(rows[0]).toMatchObject({ type: "workspace", id: "ws-eff" });
  expect(rows[1]?.type).toBe("ask");
});

test("a tab's exact title leads even though its row shows the cleaned title", () => {
  const rows = screenRows("Reddit - The heart of the internet", photo);
  expect(rows[0]).toMatchObject({ type: "tab", id: "reddit-tab" });
  expect(rows[1]?.type).toBe("ask");
});
