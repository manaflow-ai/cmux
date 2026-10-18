import type { AcpmuxSnapshot } from "../model";

/// A page with no session yet, after a folder pick (`projectDraft`): its composer names that folder.
export function withDraftFolder(snapshot: AcpmuxSnapshot, projectDraft: string | undefined): AcpmuxSnapshot {
  if (!projectDraft || snapshot.sessionId) return snapshot;
  return { ...snapshot, summary: { sessionId: "", cwd: projectDraft } } as AcpmuxSnapshot;
}
