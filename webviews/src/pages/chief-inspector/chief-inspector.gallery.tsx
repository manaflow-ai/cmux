// l10n-allow-file: gallery fixtures (sample memory), not shipped UI.
// The remote Chief memory inspector page (cmux-page://cmux.chief-inspector/): the same App the page
// entry (main.tsx) mounts, over a store whose fetcher answers from fixed inspector API replies
// instead of the `cmux.chief_inspector.get` bridge op.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { App, type Tab } from "../../optchat-inspector/App";
import { ApiStore, type Fetcher } from "../../optchat-inspector/store";
import type { Status, TurnPrompt, TurnRow } from "../../optchat-inspector/types";
import { StoreContext } from "../../optchat-inspector/useApi";

const usage = { input: 1_820, cache_read: 41_200, cache_write: 2_300, output: 640 };

const turns: TurnRow[] = [
  {
    turn: "t-41",
    first: 1_201,
    ts: 1_760_000_000_000,
    harness: "claude",
    model: "sample-model",
    status: "ok",
    ms: 8_400,
    usage,
    requests: 3,
    tools: 4,
    tool_errors: 0,
    hit_rate: 0.92,
  },
  {
    turn: "t-42",
    first: 1_214,
    ts: 1_760_000_600_000,
    harness: "claude",
    model: "sample-model",
    status: "ok",
    ms: 5_100,
    usage,
    requests: 2,
    tools: 1,
    tool_errors: 0,
    hit_rate: 0.95,
  },
];

const status: Status = {
  messages: 1_230,
  view_lines: 18,
  view_bytes: 9_400,
  budget: 12_000,
  unbuilt: 0,
  nodes_built: 64,
  busy: [],
  failures: [],
  fatal: null,
  closed: false,
  settled: true,
  settle: null,
  top_level: 3,
  running_turn: null,
  last_turn: turns[1]!,
  last_error: null,
  trace_on: false,
  constants: {
    node_bytes: 2_048,
    view_bytes: 12_000,
    marks: [4_000, 8_000],
    grid: 1_000,
    placeholder: "…",
  },
};

const viewText =
  "L3.0 Release planning and the dock rework\nL2.4 Inspector page over the owner session\n";

const prompt: TurnPrompt = {
  turn: "now",
  harness: "claude",
  model: "sample-model",
  layout: "cached",
  exact: { view: true, system: true, messages: true },
  note: null,
  view: { text: viewText, bytes: viewText.length, marks: [], grid: [], parts: ["L3.0", "L2.4"] },
  messages: [{ id: 1_230, kind: "user", text: "Show me what the Chief remembers about the dock." }],
  system_parts: [
    {
      label: "Instructions",
      explain: "The harness's fixed system text.",
      text: "You are the Chief.",
      bytes: 18,
    },
  ],
};

const replies: Record<string, unknown> = {
  "/api/status": status,
  "/api/turns": { turns },
  "/api/turn": prompt,
};

/** Answers by path; `unreachable` answers every call with the error the bridge reports. */
function fixtureFetcher(unreachable: boolean): Fetcher {
  return async (url) => {
    if (unreachable) throw new Error("The server's Chief is not reachable.");
    const reply = replies[new URL(url, "cmux-page://cmux.chief-inspector/").pathname];
    if (reply === undefined) throw new Error(`No fixture for ${url}`);
    return reply;
  };
}

type Props = { tab: Tab; unreachable?: boolean };

function ChiefInspectorGallery({ tab, unreachable = false }: Props) {
  const [store] = useState(() => new ApiStore(fixtureFetcher(unreachable)));
  return (
    <StoreContext.Provider value={store}>
      <App initialTab={tab} />
    </StoreContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "pages.chief-inspector",
  title: "Chief memory inspector",
  area: "Pages",
  height: 640,
  covers: ["page:cmux.chief-inspector"],
  load: async () => ChiefInspectorGallery,
  styles: () => import("../../optchat-inspector/styles.css"),
  variants: {
    prompt: {
      note: "The next turn's prompt: system parts, view and new messages.",
      props: { tab: "prompt" },
    },
    timeline: { note: "Two recorded turns with cache hit rates.", props: { tab: "timeline" } },
    unreachable: {
      note: "The paired server's Chief does not answer.",
      props: { tab: "prompt", unreachable: true },
    },
  },
});
