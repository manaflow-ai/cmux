import { useEffect, useRef } from "react";
import { workflowPaneRequest } from "../summary/workflowTranscript";
import { agentTone } from "./agentTones";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Keep the pane tab's identity in step with its transcript. A workflow uses this placement
/// transport but is not a subagent: clear any previous child's ink, even before it has a title.
export function useShownSubagent(call: Call, ownPane: boolean, id: string | undefined, title: string | undefined) {
  const shownOnce = useRef(false);
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
      id ? { subagent: id, ...(title ? { title } : {}), ...(workflow ? {} : { tone: agentTone(id) }) } : {},
    ).catch(() => undefined);
  }, [call, ownPane, id, title]);
}
