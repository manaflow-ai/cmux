// A Chief chat's agents on the Messages page (HomeNativeTranscriptView+AgentPane, HomeAgentMessages):
// one agents row of pills under each Chief message that told or heard from them. A click on a pill
// opens the agent's own workspace as its `aN` link does (user 2026-11-04, msg 21663): the Chief's
// link to its session goes to the host, which opens it right of Home. Home never splits (user
// 2026-11-07, msg 23836: "get rid of the imessage home split pane completely"): with no link (a
// queued agent) the click does nothing. The rows read the runs the page holds for its loaded
// messages, so the work grows with the window, not with the chat.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { HomeChannelsStore } from "../../../home-channels/store";
import type { RunEntry } from "../../../home-channels/runs";
import type { HomeMessage } from "../../../home-channels/types";
import type { Strings } from "../../../shared/i18n";
import type { TranscriptExtra } from "../../transcript/extras";
import { AgentPills } from "./AgentPills";
import { agentRows, agentWorkspaceLink, newestReportAt } from "./agentRuns";

/** At most this many runs without all their steps are read for the rows (the newest first). */
export const AGENT_STEP_READS = 20;

/** The runs of the loaded messages: each reply's run and the runs working on each message. */
export function windowEntries(
  runs: {
    forReply(message: HomeMessage): RunEntry | undefined;
    liveFor(message: HomeMessage, all?: boolean): RunEntry[];
  },
  messages: readonly HomeMessage[],
): RunEntry[] {
  const seen = new Set<RunEntry>();
  const out: RunEntry[] = [];
  const add = (entry: RunEntry | undefined) => {
    if (!entry || seen.has(entry)) return;
    seen.add(entry);
    out.push(entry);
  };
  for (const message of messages) {
    add(runs.forReply(message));
    for (const entry of runs.liveFor(message, true)) add(entry);
  }
  return out;
}

export interface AgentsView {
  /** The pills rows, by the message each goes under. */
  after: Map<string, TranscriptExtra[]>;
}

export function useAgents(
  store: HomeChannelsStore,
  messages: readonly HomeMessage[],
  me: string | undefined,
  /** Opens a link right of Home; false: there is no host to open it. */
  openOutside: ((link: string) => boolean) | undefined,
  strings: Strings,
  enabled: boolean,
): AgentsView {
  const version = useSyncExternalStore(store.runs.subscribe, store.runs.getVersion);
  const entries = useMemo(
    () => (enabled ? windowEntries(store.runs, messages) : []),
    // `version`: the book's entries changed (a step, a summary).
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- version stands for the book's contents
    [enabled, store.runs, messages, version],
  );
  // The rows need the steps: read the newest runs that lack some (the store reads each once per rev).
  useEffect(() => {
    const missing = entries.filter((entry) => !entry.complete && entry.run.stepCount > entry.steps.length);
    for (const entry of missing.sort((a, b) => b.run.startedAt - a.run.startedAt).slice(0, AGENT_STEP_READS))
      void store.loadRunSteps(entry.run);
  }, [entries, store]);
  // The newest report the person opened, by agent (the pill's unread dot); this page's own.
  const [seen, setSeen] = useState<ReadonlyMap<string, number>>(() => new Map());
  const rows = useMemo(() => agentRows(messages, entries, seen), [messages, entries, seen]);
  const latest = useRef({ entries, messages, me });
  latest.current = { entries, messages, me };
  const open = useMemo(
    () => (peer: string) => {
      const { entries: held, messages: loaded, me: person } = latest.current;
      const link = agentWorkspaceLink(peer, loaded, person);
      if (!link || !openOutside?.(link)) return;
      const at = newestReportAt(peer, held);
      if (at === undefined) return;
      setSeen((seenAt) => ((seenAt.get(peer) ?? -1) >= at ? seenAt : new Map(seenAt).set(peer, at)));
    },
    [openOutside],
  );
  const after = useMemo(() => {
    const out = new Map<string, TranscriptExtra[]>();
    for (const [anchor, row] of rows)
      out.set(anchor, [
        {
          key: `agents:${anchor}`,
          estimate: 40,
          node: <AgentPills row={row} strings={strings} onOpen={open} />,
        },
      ]);
    return out;
  }, [rows, strings, open]);
  return { after };
}
