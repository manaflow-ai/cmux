// l10n-allow-file: gallery fixtures, not shipped UI.
// Web search and fetch rows as result cards (WebSources.tsx). Leo, 2026-11-08: "The little minor
// things where it's like, oh, f***. Like, just because of this, I'm out." A search keeps its one
// 24px Sources line under the row; each named site now shows its icon, and the list it opens is a
// row per page (icon, title, site). A fetch is one link card: icon, page title, site. Icons are
// what cmux has from its browser (link.inspect); a site it has none for keeps the globe in the same
// slot. Flat tonal fills, no ring. Two alternatives are drawn for comparison.
import type { Play } from "../../../gallery/play";
import type { ChipHostFixture } from "../../../gallery/format";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";

/// A public-safe stand-in favicon: a rounded tile of one color with a letter.
const mark = (fill: string, letter: string) =>
  `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="3" fill="${fill}"/><text x="8" y="12" font-family="sans-serif" font-size="10" font-weight="700" text-anchor="middle" fill="#fff">${letter}</text></svg>`,
  )}`;

const DOCS = "https://docs.example.dev/guide/streaming-responses";
const LINKS = [
  { title: "Streaming responses: guide", url: DOCS },
  { title: "Server-sent events in the browser", url: "https://developer.example.org/docs/Web/API/EventSource" },
  { title: "Why my stream buffers behind a proxy", url: "https://forum.example.net/t/stream-buffering/4412" },
  { title: "sse-starter: a minimal streaming server", url: "https://code.example.com/acme/sse-starter" },
  { title: "Chunked transfer encoding", url: "https://wiki.example.org/Chunked_transfer_encoding" },
];

const chipHost: ChipHostFixture = {
  sites: {
    [DOCS]: { icon: mark("#d97757", "D"), title: "Streaming responses: guide" },
    [LINKS[1].url]: { icon: mark("#2f855a", "M") },
    [LINKS[3].url]: { icon: mark("#24292f", "C") },
    // The forum and the wiki have no icon in cmux: the globe holds their slot.
  },
};

const search = () =>
  tool("Search streaming responses buffer behind nginx", "fetch", "completed", {
    inputSummary: JSON.stringify({ query: "streaming responses buffer behind nginx" }),
    output: [
      'Web search results for query: "streaming responses buffer behind nginx"',
      "",
      `Links: ${JSON.stringify(LINKS)}`,
      "",
      "Proxies buffer responses by default; turn proxy buffering off for the stream's route.",
    ].join("\n"),
  });

const fetch = () =>
  tool(`Fetch ${DOCS}`, "fetch", "completed", {
    inputSummary: JSON.stringify({ url: DOCS, prompt: "How do I stop a proxy buffering the stream?" }),
    output: "Set `X-Accel-Buffering: no` on the response, or turn off proxy buffering for the route.",
  });

const fetchUnknown = () =>
  tool("Fetch https://wiki.example.org/Chunked_transfer_encoding", "fetch", "completed", {
    output: "Chunked transfer encoding sends the body in a series of chunks.",
  });

const turn = () =>
  chat([
    user("Why does the chat stream arrive all at once in production?", 3),
    activity([search()], 2),
    activity([fetch(), fetchUnknown()], 2),
    assistant("The proxy buffers the response. Send `X-Accel-Buffering: no` on the stream's route.", 1),
  ]);

const openList: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("button.cv-web-sources__chip"));
  ctx.document.querySelector<HTMLButtonElement>("button.cv-web-sources__chip")?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-web-sources__list"));
};

const restyled =
  (css: string, open = true): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = css;
    ctx.document.head.append(style);
    if (open) await openList(ctx);
  };

export default agentPaneEntry({
  id: "agent-pane.web-result-cards",
  title: "Web search and fetch results as cards",
  area: "Agent pane",
  height: 760,
  covers: [
    "agent-session/acpmux/conversation/WebSources.tsx",
    "agent-session/acpmux/conversation/webSourceList.ts",
    "agent-session/acpmux/conversation/ToolRow.tsx",
  ],
  variants: {
    closed: {
      note: "Selected, closed: the search's Sources line names its first sites, each with its icon (the globe where cmux has none), then +N. Each fetch is one link card: icon, the page's title (or where it sits on its site), its site. Same 24px line as before, so nothing moves.",
      snapshot: turn(),
      chipHost,
    },
    rows: {
      note: "Selected, opened: the search lists one row per page, icon, title and site. A click opens the page in a cmux tab.",
      snapshot: turn(),
      chipHost,
      play: openList,
    },
    "stacked-marks": {
      note: "Alternative: the closed line shows only the sites' icons, overlapped, then the count. Tighter, but a site with no icon reads as a row of globes and the names are gone until it opens.",
      snapshot: turn(),
      chipHost,
      play: restyled(
        ".cv-web-sources__host { display: none; } .cv-web-sources__hosts { gap: 0; } .cv-web-sources__named + .cv-web-sources__named { margin-left: -4px; } .cv-web-sources__named .cv-web-sources__icon { border-radius: 4px; background: var(--cv-card-fill); }",
        false,
      ),
    },
    "two-line-rows": {
      note: "Alternative: opened rows with the title over its site and path, as a search engine lists them. Reads well alone, but doubles the list's height for ten results and the site repeats what the icon says.",
      snapshot: turn(),
      chipHost,
      play: restyled(
        ".cv-web-sources__page { display: grid; grid-template-columns: 14px 1fr; column-gap: 8px; padding: 4px 8px; } .cv-web-sources__page .cv-web-sources__icon { grid-row: span 2; } .cv-web-sources__page .cv-web-sources__site { grid-column: 2; }",
      ),
    },
  },
});
