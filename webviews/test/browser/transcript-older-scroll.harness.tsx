// The chat's transcript with older history paging in as the reader scrolls up (App.tsx checkOlder),
// for transcript-older-scroll.test.ts: the chat opens on its tail, and each ask lands one page of
// older rows above the first after `window.__older.latency` ms, as a read from acpmux would.
// For transcript-tail-scroll.test.ts: `?tail=N` opens on the last N rows, `?latency=ms` sets how
// long each page takes, and `?prompts` passes the chat's prompt count, as the pane does, so the room
// for the unloaded history is held above the rows (conversation/olderReserve.ts).
// For transcript-older-scroll.test.ts's reconnect case: `__older.live()` appends a turn, as a reply
// streaming on does, and `__older.reconnect("tail" | "empty")` draws what a reconnect or a rebuild
// draws first: only the chat's newest tail (the older pages read so far gone), or no rows for a frame.
import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { syntheticRows } from "../../src/agent-session/acpmux/synthetic";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
// The prompt rail sits sticky over the rows at no height, as the pane draws it; unstyled, it took
// its rail's height above the rows and moved them as the rail grew with each older page.
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

/// Rows past the chat's first 3000 that `live()` appends, a turn (three rows) at a time.
const LIVE = 300;
const all = syntheticRows(3000 + LIVE);
const PAGE = 30;
type Older = {
  latency: number;
  /** Each ask: when it was made, the offset then, and when its page landed. */
  asks: { at: number; top: number; landed?: number }[];
  loaded: () => number;
  total: number;
  live: () => void;
  reconnect: (draws: "tail" | "empty") => void;
};
const query = new URLSearchParams(location.search);
const TAIL = Number(query.get("tail") ?? 2 * PAGE);
const older: Older = {
  latency: Number(query.get("latency") ?? 400),
  asks: [],
  loaded: () => 0,
  total: all.length - LIVE,
  live: () => {},
  reconnect: () => {},
};
(window as unknown as { __older: Older }).__older = older;

function Transcript() {
  const [end, setEnd] = useState(all.length - LIVE);
  // `?all`: every row from the start and nothing to page, the control the paging is measured against.
  const [from, setFrom] = useState(query.has("all") ? 0 : all.length - LIVE - TAIL);
  const [blank, setBlank] = useState(false);
  // The test's handles read this commit's rows: set after each commit, before the test reads them.
  useLayoutEffect(() => {
    older.loaded = () => end - from;
    older.total = end;
    older.live = () => setEnd((at) => Math.min(all.length, at + 3));
    older.reconnect = (draws) => {
      if (draws === "empty") setBlank(true);
      else setFrom(Math.max(0, end - TAIL));
    };
  });
  // A rebuild's empty frame lasts one commit: the rows it held come back in the next.
  useEffect(() => {
    if (blank) setBlank(false);
  }, [blank]);
  const onLoadOlder = useCallback(() => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    const ask: Older["asks"][number] = { at: performance.now(), top: scroller?.scrollTop ?? -1 };
    older.asks.push(ask);
    return new Promise<void>((resolve) =>
      // fixed-wait: the read's latency is the behavior under test, the time a page takes to land.
      setTimeout(() => {
        ask.landed = performance.now();
        setFrom((at) => Math.max(0, at - PAGE));
        resolve();
      }, older.latency),
    );
  }, []);
  return (
    <VirtualTranscript
      rows={blank ? [] : turnView(all.slice(from, end), new Set())}
      sessionId="session-older"
      onToggleActivity={() => {}}
      expanded={new Set()}
      canLoadOlder={from > 0}
      promptCount={query.has("prompts") && from > 0 ? end / 3 : undefined}
      onLoadOlder={onLoadOlder}
    />
  );
}
createRoot(root).render(<Transcript />);
