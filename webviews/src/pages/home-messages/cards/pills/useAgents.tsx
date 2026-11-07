// A Chief chat's agents on the Messages page (HomeNativeTranscriptView+AgentPane, HomeAgentMessages):
// one agents row of pills under each Chief message that told or heard from them, and the agent pane on
// the chat's right. A click on a pill opens the agent's chat as its `aN` link does (user 2026-11-04,
// msg 21663): the Chief's link to its session goes to the host, which opens a chat tab right of Home;
// with no link or no host, the pane here shows it. The rows read the runs the page holds for its
// loaded messages, so the work grows with the window, not with the chat.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { HomeChannelsStore } from "../../../home-channels/store";
import type { RunEntry } from "../../../home-channels/runs";
import type { HomeMessage } from "../../../home-channels/types";
import { useNow } from "../../../home-channels/RunCard";
import type { Strings } from "../../../shared/i18n";
import type { TranscriptExtra } from "../../transcript/extras";
import { AgentPills } from "./AgentPills";
import { AgentSidePane } from "./AgentSidePane";
import {
  agentChatContent,
  closeAgent,
  EMPTY_PANE,
  openAgentOutside,
  selectAgent,
  sendToAgent,
  type AgentPaneState,
  type AgentThreadSource,
} from "./agentModel";
import { agentRows, agentThread, newestReportAt, noteText } from "./agentRuns";

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
  /** The agent pane; none while no tab is open. */
  pane?: React.ReactNode;
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
  const [pane, setPaneState] = useState<AgentPaneState>(EMPTY_PANE);
  // Opening and selecting mark reports seen and may call the host: run once per click, from the
  // pane as it is now (never inside a state updater, which React may run twice).
  const paneRef = useRef(pane);
  const setPane = useMemo(
    () => (change: (held: AgentPaneState) => AgentPaneState) => {
      const next = change(paneRef.current);
      paneRef.current = next;
      setPaneState(next);
    },
    [],
  );
  const rows = useMemo(() => agentRows(messages, entries, seen), [messages, entries, seen]);
  const latest = useRef({ entries, messages, me });
  latest.current = { entries, messages, me };
  const source = useMemo<AgentThreadSource>(
    () => ({
      thread: (peer) => {
        const { entries: held, messages: loaded, me: person } = latest.current;
        return agentThread(peer, held, loaded, person);
      },
      markSeen: (peer) => {
        const at = newestReportAt(peer, latest.current.entries);
        if (at === undefined) return;
        setSeen((held) => ((held.get(peer) ?? -1) >= at ? held : new Map(held).set(peer, at)));
      },
      send: (text, peer) => void store.send(noteText(peer, text)),
    }),
    [store],
  );
  const after = useMemo(() => {
    const out = new Map<string, TranscriptExtra[]>();
    for (const [anchor, row] of rows)
      out.set(anchor, [
        {
          key: `agents:${anchor}`,
          estimate: 40,
          node: (
            <AgentPills
              row={row}
              strings={strings}
              onOpen={(peer) =>
                setPane((held) => openAgentOutside(held, peer, source, (link) => openOutside?.(link) ?? false)[0])
              }
            />
          ),
        },
      ]);
    return out;
  }, [rows, strings, source, openOutside, setPane]);
  const shown = pane.tabs.length ? (
    <AgentPane pane={pane} source={source} strings={strings} openOutside={openOutside} setPane={setPane} />
  ) : undefined;
  return { after, ...(shown ? { pane: shown } : {}) };
}

function AgentPane({
  pane,
  source,
  strings,
  openOutside,
  setPane,
}: {
  pane: AgentPaneState;
  source: AgentThreadSource;
  strings: Strings;
  openOutside: ((link: string) => boolean) | undefined;
  setPane(change: (held: AgentPaneState) => AgentPaneState): void;
}) {
  // "Working for …" ticks only while the pane shows a working agent (useNow stops with it).
  const selected = pane.selected ? source.thread(pane.selected) : undefined;
  const now = useNow(selected?.state === "told" || selected?.state === "queued");
  return (
    <AgentSidePane
      pane={pane}
      content={(peer) => {
        const thread = source.thread(peer);
        return thread ? agentChatContent(thread, now, strings) : undefined;
      }}
      strings={strings}
      onSelect={(peer) => setPane((held) => selectAgent(held, peer, source))}
      onClose={(peer) => setPane((held) => closeAgent(held, peer, source))}
      onGoToWorkspace={(peer) => {
        const link = source.thread(peer)?.workspaceLink;
        if (link) openOutside?.(link);
      }}
      onSend={(peer, text) => sendToAgent(pane, peer, text, source)}
    />
  );
}
