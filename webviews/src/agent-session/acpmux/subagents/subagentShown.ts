import { useEffect, useRef } from "react";
import { workflowPaneRequest } from "../summary/workflowTranscript";
import { agentTone } from "./agentTones";
import type { Subagent } from "./subagentFold";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// What a subagent pane's tab says of its subagent (SubagentTabFacts.swift): its own state, since
/// when on this computer's clock, and its model. Without them the tab reads its chat's state, as
/// the chat's own session ("Working · 4m" for a subagent that finished: Leo, 2026-11-07, "is this
/// your sub-agent, or is this literally just a duplicate of you?").
export type ShownSubagentFacts = { state: string; sinceMs?: number; model?: string };

/// `agent`'s facts; `clockOffset` is the snapshot's `clockOffsetMs` (this computer's clock minus
/// the session's).
export function shownSubagentFacts(
  agent: Pick<Subagent, "state" | "startedAt" | "endedAt" | "model">,
  clockOffset = 0,
): ShownSubagentFacts {
  const since = agent.state === "running" ? agent.startedAt : (agent.endedAt ?? agent.startedAt);
  return {
    state: agent.state,
    ...(since > 0 && { sinceMs: since + clockOffset }),
    ...(agent.model && { model: agent.model }),
  };
}

/// Keep the pane tab's identity in step with its transcript. A workflow uses this placement
/// transport but is not a subagent: clear any previous child's ink, even before it has a title.
export function useShownSubagent(
  call: Call,
  ownPane: boolean,
  id: string | undefined,
  title: string | undefined,
  facts?: ShownSubagentFacts,
) {
  const shownOnce = useRef(false);
  const { state, sinceMs, model } = facts ?? {};
  useEffect(() => {
    if (!ownPane) return;
    const workflow = workflowPaneRequest(id);
    if (id) {
      shownOnce.current = true;
      // A real subagent's rows can arrive after the pane opens. Keep its initial identity until then.
      if (!title && !workflow) return;
    } else if (!shownOnce.current) return;
    void call(
      "chat.subagentShown",
      id
        ? {
            subagent: id,
            ...(title ? { title } : {}),
            ...(workflow ? {} : { tone: agentTone(id) }),
            ...(!workflow && state ? { state, ...(sinceMs ? { sinceMs } : {}), ...(model ? { model } : {}) } : {}),
          }
        : {},
    ).catch(() => undefined);
  }, [call, ownPane, id, title, state, sinceMs, model]);
}
