import { useEffect, useMemo, useReducer, useRef, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { SUBAGENT_OF } from "../subagents/subagentRows";
import type { WorkflowAgent } from "./workflow";
import { workflowPaneRequest, WorkflowTranscript, type TranscriptRead } from "./workflowTranscript";

/// Selection owns the reader lifetime; its run's progress and this agent's state request a refresh.
export function useWorkflowTranscript(
  id: string | undefined,
  sessionId: string | undefined,
  enabled: boolean,
  agent: WorkflowAgent | undefined,
  chat: string,
  read: TranscriptRead,
  connection: string,
) {
  const t = useT();
  const [revision, redraw] = useReducer((n: number) => n + 1, 0);
  const readRef = useRef(read);
  readRef.current = read;
  const request = useMemo(() => workflowPaneRequest(id), [id]);
  const [active, setActive] = useState<WorkflowTranscript>();
  useEffect(() => {
    if (!enabled || !request || request.sessionId !== sessionId) {
      setActive(undefined);
      return;
    }
    const next = new WorkflowTranscript(request, (params) => readRef.current(params), redraw);
    setActive(next);
    return () => next.dispose();
  }, [request, sessionId, enabled]);
  const reader = active?.request === request ? active : undefined;
  useEffect(() => {
    void reader?.refresh();
  }, [
    reader,
    agent?.lastProgressAt,
    agent?.progressVersion,
    agent?.state,
    agent?.doing,
    agent?.tokens,
    agent?.lastMessage,
    connection,
  ]);
  const rows = useMemo((): AcpmuxRow[] | undefined => {
    if (!enabled || !request || request.sessionId !== sessionId || !id) return undefined;
    const pill: AcpmuxRow = {
      id: `${id}:of`,
      version: revision,
      at: 0,
      kind: SUBAGENT_OF,
      text: chat,
      subagents: [
        {
          id,
          parent: null,
          name: agent?.name ?? request!.agentId,
          task: agent?.name,
          state: agent?.state ?? "unknown",
          startedAt: agent?.startedAt ?? 0,
        },
      ],
    };
    const notice = reader?.failed
      ? t("workflow.detailUnavailable")
      : (!reader || reader.loading) && !reader?.rows.length
        ? t("replay.loading")
        : reader?.truncated
          ? t("workflow.historyLimited")
          : undefined;
    return [
      pill,
      ...(reader?.rows ?? []),
      ...(notice
        ? [
            {
              id: `${id}:notice`,
              version: revision,
              at: 0,
              kind: "notice",
              text: notice,
            },
          ]
        : []),
    ];
  }, [reader, id, chat, agent, request, t, revision, enabled, sessionId]);
  return {
    rows,
    canLoadOlder: reader?.canLoadOlder ?? false,
    historyFrom: reader?.historyFrom,
    loadOlder: () => reader?.loadOlder() ?? Promise.resolve(),
  };
}
