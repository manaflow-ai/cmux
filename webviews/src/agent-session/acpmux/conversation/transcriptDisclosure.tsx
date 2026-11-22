import { type ReactNode } from "react";
import { useTranscriptView } from "./transcriptView";
import { DEFAULT_SESSION, DisclosureSession, ViewContext, viewChat } from "./transcriptDisclosureModel";
export function TranscriptDisclosureProvider({ sessionId, children }: { sessionId?: string; children: ReactNode }) {
  const view = useTranscriptView(viewChat(sessionId));
  return (
    <DisclosureSession.Provider value={sessionId || DEFAULT_SESSION}>
      <ViewContext.Provider value={view}>{children}</ViewContext.Provider>
    </DisclosureSession.Provider>
  );
}
