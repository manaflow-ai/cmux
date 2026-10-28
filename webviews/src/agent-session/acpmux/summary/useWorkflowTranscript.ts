import { useEffect, useMemo, useReducer, useRef } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { SUBAGENT_OF } from "../subagents/subagentRows";
import type { WorkflowAgent } from "./workflow";
import { workflowPaneRequest, WorkflowTranscript, type TranscriptRead } from "./workflowTranscript";

/// Selection owns the reader lifetime; only this agent's progress/state fields request a refresh.
export function useWorkflowTranscript(
  id: string | undefined,
  sessionId: string | undefined,
  enabled: boolean,
  agent: WorkflowAgent | undefined,
  chat: string,
  read: TranscriptRead,
) {
  const t = useT();
  const [, redraw] = useReducer((n: number) => n + 1, 0);
  const readRef = useRef(read);
  readRef.current = read;
  const request = useMemo(() => workflowPaneRequest(id), [id]);
  const reader = useMemo(
    () =>
      enabled && request?.sessionId === sessionId
        ? new WorkflowTranscript(request, (params) => readRef.current(params), redraw)
        : undefined,
    [request, sessionId, enabled],
  );
  useEffect(() => () => reader?.dispose(), [reader]);
  useEffect(() => {
    void reader?.refresh();
  }, [reader, agent?.lastProgressAt, agent?.state, agent?.doing, agent?.tokens, agent?.lastMessage]);
  const rows = useMemo((): AcpmuxRow[] | undefined => {
    if (!reader || !id) return undefined;
    const pill: AcpmuxRow = {
      id: `${id}:of`,
      version: 1,
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
    const notice = reader.failed
      ? t("workflow.detailUnavailable")
      : reader.loading && !reader.rows.length
        ? t("replay.loading")
        : reader.truncated
          ? t("inspector.olderDropped")
          : undefined;
    return [
      pill,
      ...reader.rows,
      ...(notice
        ? [
            {
              id: `${id}:notice`,
              version: reader.failed ? 2 : 1,
              at: 0,
              kind: "notice",
              text: notice,
            },
          ]
        : []),
    ];
  }, [reader, id, chat, agent, request, t, reader?.rows, reader?.loading, reader?.failed]);
  return {
    rows,
    canLoadOlder: reader?.canLoadOlder ?? false,
    loadOlder: () => reader?.loadOlder() ?? Promise.resolve(),
  };
}
