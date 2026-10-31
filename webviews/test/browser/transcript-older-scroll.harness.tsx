// The chat's transcript with older history paging in as the reader scrolls up (App.tsx checkOlder),
// for transcript-older-scroll.test.ts: the chat opens on its tail, and each ask lands one page of
// older rows above the first after `window.__older.latency` ms, as a read from acpmux would.
import { useCallback, useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { syntheticRows } from "../../src/agent-session/acpmux/synthetic";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

const all = syntheticRows(3000);
const PAGE = 30;
type Older = {
  latency: number;
  /** Each ask: when it was made, the offset then, and when its page landed. */
  asks: { at: number; top: number; landed?: number }[];
  loaded: () => number;
  total: number;
};
const older: Older = { latency: 400, asks: [], loaded: () => 0, total: all.length };
(window as unknown as { __older: Older }).__older = older;

function Transcript() {
  // `?all`: every row from the start and nothing to page, the control the paging is measured against.
  const [from, setFrom] = useState(location.search.includes("all") ? 0 : all.length - 2 * PAGE);
  older.loaded = () => all.length - from;
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
      rows={turnView(all.slice(from), new Set())}
      sessionId="session-older"
      onToggleActivity={() => {}}
      expanded={new Set()}
      canLoadOlder={from > 0}
      onLoadOlder={onLoadOlder}
    />
  );
}
createRoot(root).render(<Transcript />);
