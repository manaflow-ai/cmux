// Per-pane progress subscriptions keep usage-only updates out of structural row lists.
import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { usePaneLanguage, useT } from "../i18n";
import type { Subagent } from "./subagentFold";
import { subagentProgress } from "./subagentProgress";
import { frameNotification } from "../../../ui/frameNotifications";
import { useLiveUpdates } from "../../../ui/liveUpdates";

import { AgentProgressStore } from "./agentProgressSource";
export { AgentProgressStore } from "./agentProgressSource";
const EMPTY = {};

export const AgentProgressContext = createContext<AgentProgressStore | undefined>(undefined);
/// An agent's live progress line, without tokens or tool uses: no subagent list says them, only
/// the Inspector's Context does (subagentProgress.ts).
export function useAgentProgress(agent?: Subagent): string | undefined {
  const store = useContext(AgentProgressContext);
  const id = agent?.id;
  const active = useLiveUpdates();
  const t = useT();
  const language = usePaneLanguage();
  const subscribe = useCallback(
    (notify: () => void) => {
      if (!active || !store || id === undefined) return () => {};
      const frame = frameNotification(notify);
      const stop = store.subscribe(id, frame.schedule);
      return () => {
        stop();
        frame.cancel();
      };
    },
    [active, store, id],
  );
  // The row draws workflow counts, not token/tool usage. A new source object with the same
  // displayed text must not reconcile the row (twenty busy agents otherwise do this per event).
  const snapshot = useCallback(
    () =>
      id === undefined
        ? undefined
        : subagentProgress(t, language, store ? store.get(id) : (agent ?? EMPTY), { usage: false }).join(" · "),
    [store, id, agent, t, language],
  );
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}
