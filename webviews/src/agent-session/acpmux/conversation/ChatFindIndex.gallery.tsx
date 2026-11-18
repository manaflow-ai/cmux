// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Find in Chat over the whole transcript (findIndex.ts; Leo, 2026-11-18: "shouldn't you be able to
// like have better tools for finding stuff?"): the bar and a short loaded transcript over the real
// find state (useChatFind) with a stand-in for the daemon's transcript index. The variants: the
// index's hits in turns not loaded counted with the loaded matches, the index still answering, a
// step to a hit whose turn is paging in, that hit loaded and highlighted after the jump, and a
// daemon with no index (Find reads the loaded rows, as before).
import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { ChatFindBar } from "./ChatFindBar";
import { clearFindHighlights, paintFindHighlights, useChatFind } from "./chatFind";
import type { FindIndexSource, IndexAnswer, IndexHit } from "./findIndex";

type Mode = "hits" | "searching" | "loading" | "landed" | "absent";

const loaded = [
  user("Why does the retry loop give up after one try?", 6),
  assistant("The retry count is read before the config loads, so it is 1. Move the retry read after load.", 5),
  user("Fix it and add a retry test.", 4),
  assistant("Done: the retry count now comes from the loaded config.", 3),
];
const oldest = loaded[0]!.at;
const DAY = 24 * 60 * 60_000;
/// The turns before the loaded page: "retry" 36 more times, "flaky" three times, days earlier.
const olderRetry: IndexHit[] = Array.from({ length: 36 }, (_, at) => ({ at: oldest - DAY + at * 60_000, seq: at + 1 }));
const olderFlaky: IndexHit[] = [0, 1, 2].map((at) => ({ at: oldest - DAY + at * 60_000, seq: 100 + at }));
/// The turn a step to the newest "flaky" hit pages in: two loaded matches stand for it and the
/// hit's two older neighbours stay counted ("3 of 4").
const landedTurn = [
  user("The flaky test fails one run in ten on CI.", 60 * 24 + 1, { id: "flaky-prompt" }),
  assistant("It is flaky because two tests share one temp folder; each now makes its own.", 60 * 24, {
    id: "flaky-answer",
  }),
];

const never = new Promise<never>(() => undefined);

/// The stand-in index for `mode`: what the daemon answers, and what a load pages in.
function indexFor(mode: Mode, land: (rows: AcpmuxRow[]) => void): FindIndexSource {
  const answer = (query: string): IndexAnswer => {
    const hits = query.toLowerCase().includes("retry") ? olderRetry : query.toLowerCase().includes("flaky") ? olderFlaky : [];
    return { hits, total: hits.length };
  };
  return {
    key: "gallery-chat",
    search: (search) =>
      mode === "absent"
        ? Promise.resolve(undefined)
        : mode === "searching"
          ? never
          : Promise.resolve(answer(search.query)),
    holdsSeq: (seq) => seq >= 1_000,
    load: () => {
      if (mode !== "landed") return never;
      land(landedTurn);
      return Promise.resolve(true);
    },
  };
}

function Board({ mode }: { mode: Mode }) {
  const [older, setOlder] = useState<AcpmuxRow[]>([]);
  const rows = useMemo(() => [...older, ...loaded], [older]);
  const index = useMemo(
    () => ({
      ...indexFor(mode, setOlder),
      // A landed hit's rows are held: the daemon's seq for it is the oldest loaded one.
      holdsSeq: (seq: number) => seq >= (older.length ? 102 : 1_000),
    }),
    [mode, older.length],
  );
  const find = useChatFind(rows, index);
  const board = useRef<HTMLDivElement>(null);
  const target = find.open ? find.matches[find.active] : undefined;
  // The highlights over the rows, the current match apart, as the transcript paints them, and the
  // current match's row brought into view.
  useLayoutEffect(() => {
    const root = board.current;
    if (!root) return;
    if (!find.query) return clearFindHighlights();
    const current = paintFindHighlights(
      root,
      find.query,
      target ? { rowId: target.rowId, card: false, occurrence: target.occurrence } : undefined,
    );
    current?.startContainer.parentElement?.scrollIntoView({ block: "nearest" });
  });
  useLayoutEffect(() => clearFindHighlights, []);
  return (
    <div
      ref={board}
      className="acpmux-shell"
      style={
        {
          position: "relative",
          height: "100%",
          overflow: "auto",
          display: "block",
          "--acpmux-session-info-clear": "0px",
        } as CSSProperties
      }
      onFocusCapture={() => {
        if (!find.open) find.show();
      }}
    >
      <ChatFindBar find={find} />
      <div
        className="selectable"
        style={{
          display: "grid",
          gap: "var(--ds-space-3)",
          padding: "var(--ds-space-56) var(--ds-space-5) var(--ds-space-5)",
          fontSize: "var(--text-content)",
          lineHeight: 1.5,
        }}
      >
        {rows.map((row) => (
          <div
            key={row.id}
            data-row-id={row.id}
            style={
              row.kind === "user"
                ? {
                    justifySelf: "end",
                    maxWidth: "80%",
                    padding: "var(--ds-space-2) var(--ds-space-3)",
                    borderRadius: 14,
                    background: "var(--agent-bubble, color-mix(in srgb, currentColor 8%, transparent))",
                  }
                : undefined
            }
          >
            {row.text}
          </div>
        ))}
      </div>
    </div>
  );
}

const field = { selector: ".acpmux-find .find-pill__field" };
const count = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-find .find-pill__count");
const countIs = (ctx: PlayContext, text: string) => count(ctx)?.textContent === text;
const busy = (ctx: PlayContext) => count(ctx)?.hasAttribute("data-busy") === true;
// The count's width follows its text and the bar is anchored at its right edge (ChatFindBar).
const countShift = {
  layoutShiftMax: {
    value: 0.05,
    reason: "The bar is anchored at its right edge and grows to the left when the count text first shows.",
  },
};

export default componentEntry<{ mode: Mode }>({
  id: "agent-pane.chat-find-index",
  title: "Find in Chat over the whole transcript",
  area: "Agent pane",
  height: 280,
  covers: [
    "agent-session/acpmux/conversation/ChatFindBar.tsx#ChatFindBar",
    "agent-session/acpmux/conversation/chatFind.ts#useChatFind",
  ],
  load: async () => Board,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  widths: { narrow: 360, normal: 640 },
  variants: {
    "index-hits": {
      note: "The index's hits in turns not loaded count with the loaded matches; the first loaded match stays current.",
      props: { mode: "hits" },
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("retry", field);
        await ctx.waitFor(() => countIs(ctx, "37 of 41") && !busy(ctx));
      },
    },
    searching: {
      note: "The index is still answering and no loaded row matches: a dot, not No results.",
      props: { mode: "searching" },
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("flaky", field);
        await ctx.waitFor(() => busy(ctx) && count(ctx)?.textContent === "");
      },
    },
    "loading-older": {
      note: "A step back to a hit in a turn not loaded: its turn pages in, the count reads dimmer meanwhile.",
      props: { mode: "loading" },
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("retry", field);
        await ctx.waitFor(() => countIs(ctx, "37 of 41"));
        await ctx.press("Shift+Enter");
        await ctx.waitFor(() => countIs(ctx, "36 of 41") && busy(ctx));
      },
    },
    landed: {
      note: "The hit's turn loaded: its match is current and highlighted, above the rows that were loaded.",
      props: { mode: "landed" },
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("flaky", field);
        await ctx.waitFor(
          () => countIs(ctx, "3 of 4") && !busy(ctx) && !!ctx.document.querySelector('[data-row-id="flaky-answer"]'),
        );
      },
    },
    "no-index": {
      note: "An acpmux with no transcript index: Find reads the loaded rows alone, as before.",
      props: { mode: "absent" },
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("flaky", field);
        await ctx.waitFor(
          () =>
            !!count(ctx)?.hasAttribute("data-none") &&
            ctx.document.querySelector<HTMLButtonElement>(".acpmux-find .find-pill__button")?.disabled === true,
        );
      },
    },
  },
});
