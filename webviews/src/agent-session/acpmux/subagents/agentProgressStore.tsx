// Per-pane progress subscriptions keep usage-only updates out of structural row lists.
import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { usePaneLanguage, useT } from "../i18n";
import type { Subagent } from "./subagentFold";
import { subagentProgress } from "./subagentProgress";

import { AgentProgressStore } from "./agentProgressSource";
export { AgentProgressStore } from "./agentProgressSource";
const EMPTY = {};

export const AgentProgressContext = createContext<AgentProgressStore | undefined>(undefined);
/// An agent's live progress line, without tokens or tool uses: no subagent list says them, only
/// the Inspector's Context does (subagentProgress.ts).
export function useAgentProgress(agent?: Subagent): string | undefined {
  const store = useContext(AgentProgressContext);
  const id = agent?.id;
  const subscribe = useCallback(
    (notify: () => void) => (store && id !== undefined ? store.subscribe(id, notify) : () => {}),
    [store, id],
  );
  const snapshot = useCallback(
    () => (store && id !== undefined ? store.get(id) : (agent ?? EMPTY)),
    [store, id, agent],
  );
  const progress = useSyncExternalStore(subscribe, snapshot, snapshot);
  const t = useT();
  const language = usePaneLanguage();
  return agent ? subagentProgress(t, language, progress, { usage: false }).join(" · ") : undefined;
}
