// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Find in Chat over the whole transcript on the real pane (findIndex.ts; Leo, 2026-11-18: "shouldn't
// you be able to like have better tools for finding stuff?"): a long chat on the mock daemon opens
// on its newest page, and Find asks the daemon's transcript index (mock.ts `transcriptSearch`) for a
// prompt many turns above it. The hit's turn pages in (by seq, or by older pages when the daemon
// could not place it), the rows on screen keep their place while the pages land (the stage measures
// every wait for layout shift), and then the transcript scrolls to the match and highlights it. With
// an acpmux that has no index, Find finds nothing in the loaded rows, as before.
import { agentPaneEntry } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

type PaneWindow = Window & {
  cmuxAcpmuxDebug?: { loadSeed(turns: number): Promise<unknown> };
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  cmuxAcpmuxMockTranscriptSearch?: "absent" | "noSeq";
};

const QUERY = "Turn 3: why";
const count = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-find .find-pill__count");

/// The debug socket's load_seed: a long chat recorded in the mock daemon and opened through the real
/// client, so it pages in as a chat on acpmux does (mockPaging.test.ts).
async function openLongChat(ctx: PlayContext, mode?: PaneWindow["cmuxAcpmuxMockTranscriptSearch"]) {
  const view = ctx.document.defaultView as PaneWindow;
  view.cmuxAcpmuxMockTranscriptSearch = mode;
  await ctx.waitFor(() => view.cmuxAcpmuxDebug !== undefined && view.cmuxAcpmuxActions !== undefined);
  let seeded = false;
  void view.cmuxAcpmuxDebug!.loadSeed(80).then(() => (seeded = true));
  await ctx.waitFor(() => seeded, { capMs: 30_000 });
  return view;
}

/// Cmd-F with the query, as the app's Find command opens it.
const find = (view: PaneWindow) => view.cmuxAcpmuxActions!["chat.find"]!({ text: QUERY });

/// The old turn's prompt is drawn, in view, with the current match's highlight on it.
const landed = (ctx: PlayContext) => {
  const scroller = ctx.document.querySelector(".acpmux-scroll");
  const prompt = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-scroll [data-row-id]")].find((row) =>
    row.textContent?.includes(QUERY),
  );
  if (!scroller || !prompt) return false;
  const view = scroller.getBoundingClientRect();
  const box = prompt.getBoundingClientRect();
  const highlights = (globalThis.CSS as unknown as { highlights?: Map<string, unknown> }).highlights;
  return box.bottom > view.top && box.top < view.bottom && Boolean(highlights?.has("acpmux-find-active"));
};

export default agentPaneEntry({
  id: "agent-pane.chat-find-pane",
  title: "Find in Chat: a hit in turns not loaded",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/conversation/chatFind.ts#useChatFind",
    "agent-session/acpmux/conversation/ChatFindBar.tsx#ChatFindBar",
    "agent-session/acpmux/direct.ts",
  ],
  variants: {
    "loads-by-seq": {
      note: "Play: an 80-turn chat on its newest page; Find for turn 3's prompt. The index places it by seq, the transcript loads through it, keeps its place as pages land, then scrolls to and highlights it.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const view = await openLongChat(ctx);
        await find(view);
        await ctx.waitFor(() => count(ctx)?.textContent === "1 of 1" && landed(ctx), { capMs: 30_000 });
      },
    },
    "loads-by-time": {
      note: "Play: as loads-by-seq, with an index that could not place the hit in the chat's log: older pages load toward its time.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const view = await openLongChat(ctx, "noSeq");
        await find(view);
        await ctx.waitFor(() => count(ctx)?.textContent === "1 of 1" && landed(ctx), { capMs: 30_000 });
      },
    },
    "no-index": {
      note: "Play: an acpmux with no transcript index: Find reads the loaded rows alone and finds nothing there, as before.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const view = await openLongChat(ctx, "absent");
        await find(view);
        await ctx.waitFor(() => count(ctx)?.hasAttribute("data-none") === true, { capMs: 10_000 });
      },
    },
  },
});
