// l10n-allow-file: bench fixture chat titles and folders, not shipped UI.
// The chat lists a person with many workspaces scrolls and clicks, for all-chats-list.bench.ts: the real
// components with N synthetic chats, behind a stand-in for the host's chat index.
//   #arm=history&n=500  HistoryScreen (the page the sidebar's History dot opens): N indexed chats, read
//                       a page of 100 at a time as `chats.page` does, in its own scroller.
//   #arm=live&n=500     The New Tab page's All chats (AllChatsList): N live chats (one per workspace with
//                       an agent) above N indexed ones, the whole page one scroller (.nt-screen).
// A React Profiler around the list records each commit's own time (the build aliases react-dom to its
// profiling build); `benchOpens` counts the opens a press asked the host for.
/// <reference types="vite/client" />
import { Profiler } from "react";
import { createRoot } from "react-dom/client";
import { AllChatsList, type ActiveChat } from "../../src/agent-session/acpmux/newtab/AllChatsList";
import { HistoryScreen } from "../../src/agent-session/acpmux/newtab/HistoryScreen";
import type { AllChatsRow, LoadChatsPage } from "../../src/agent-session/acpmux/newtab/allChatsListModel";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";

const params = new URLSearchParams(location.hash.slice(1));
const arm = params.get("arm") === "live" ? "live" : "history";
const n = Number(params.get("n") ?? 500);

declare global {
  interface Window {
    benchReady: boolean;
    benchRenderAt: number;
    benchOpens: number;
    benchPages: number;
    /// Set by the bench before each press: ms from the press to the frame that painted its open.
    benchPress: Promise<number>;
    /// [commitTime, actualDuration] of each commit under the Profiler.
    benchCommits: [number, number][];
  }
}
window.benchOpens = 0;
window.benchPages = 0;
window.benchCommits = [];

const NOW = Date.UTC(2026, 10, 8, 12);
const HARNESSES = ["claude", "codex", "opencode", "pi"];
const PROJECTS = ["cmux", "cmux-platform", "ghostty", "cmuxterm-hq", "leo-workspace", "subrouter"];
const VERBS = ["Fix", "Port", "Bench", "Review", "Tidy", "Draft", "Trace", "Land"];
const THINGS = [
  "the sidebar drag",
  "the palette ranker",
  "a flaky restore test",
  "the release notes",
  "the dock resize",
];

/// N chats newest first, a few minutes apart, across a handful of projects and harnesses.
const rows: AllChatsRow[] = Array.from({ length: n }, (_, index) => ({
  key: `${HARNESSES[index % 4] === "codex" ? "codex" : "claude-code"}:bench-${index}`,
  harness: HARNESSES[index % HARNESSES.length]!,
  ...(index % 11 === 5 ? {} : { title: `${VERBS[index % VERBS.length]} ${THINGS[index % THINGS.length]} #${index}` }),
  cwd: `/Users/leo/Projects/${PROJECTS[index % PROJECTS.length]}`,
  updatedAt: NOW - index * 7 * 60_000,
}));

/// The host's index: pages of `limit` behind an opaque cursor, a query filtering titles, answered after a tick.
const load: LoadChatsPage = ({ query, cursor, limit }) => {
  window.benchPages += 1;
  const matching = query ? rows.filter((row) => row.title?.toLowerCase().includes(query.toLowerCase())) : rows;
  const from = cursor ? Number(cursor) : 0;
  const to = from + limit;
  return new Promise((resolve) =>
    setTimeout(
      () =>
        resolve({
          chats: matching.slice(from, to),
          ready: true,
          design: "project",
          ...(to < matching.length ? { nextCursor: String(to) } : {}),
        }),
      1,
    ),
  );
};

const STATES: ActiveChat["state"][] = ["running", "idle", "input", "unread", "idle", "running"];
const LABELS: Record<ActiveChat["state"], string> = {
  running: "Working",
  idle: "Idle",
  input: "Needs input",
  unread: "Done",
  failed: "Failed",
  error: "Error",
};
const live: ActiveChat[] =
  arm === "live"
    ? Array.from({ length: n }, (_, index) => {
        const state = STATES[index % STATES.length]!;
        return {
          id: `live-${index}`,
          title: `${VERBS[(index + 3) % VERBS.length]} ${THINGS[(index + 1) % THINGS.length]} (workspace ${index + 1})`,
          harness: HARNESSES[index % HARNESSES.length]!,
          state,
          label: LABELS[state],
        };
      })
    : [];

/// A host open: a new workspace with the chat, answered after a frame or so.
const open = () => {
  window.benchOpens += 1;
  return new Promise<void>((resolve) => setTimeout(resolve, 20));
};

const onRender = (_id: string, _phase: string, actualDuration: number, _base: number, _start: number, commit: number) =>
  window.benchCommits.push([commit, actualDuration]);

const list =
  arm === "history" ? (
    <HistoryScreen load={load} onOpen={open} onOpenInTerminal={() => undefined} now={NOW} />
  ) : (
    <div className="nt-screen">
      <AllChatsList
        scrollParent=".nt-screen"
        load={load}
        onOpen={open}
        active={live}
        onOpenActive={() => void open()}
        onOpenInTerminal={() => undefined}
        now={NOW}
      />
    </div>
  );

window.benchRenderAt = performance.now();
createRoot(document.getElementById("root")!).render(
  <Profiler id="list" onRender={onRender}>
    {list}
  </Profiler>,
);
window.benchReady = true;
