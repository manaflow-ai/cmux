import type { AcpmuxSnapshot } from "../model";

/// A page with no session yet, after a folder pick (`projectDraft`): its composer names that folder.
/// A pick already made on the page (a switch holds its harness, model and options) stays: a
/// folder pick never puts the chips back on a default (Leo 2026-10-18). With no pick, the summary
/// names only the folder, so the chips name what a chat there starts on.
export function withDraftFolder(snapshot: AcpmuxSnapshot, projectDraft: string | undefined): AcpmuxSnapshot {
  if (!projectDraft || snapshot.sessionId) return snapshot;
  const picked = heldPick(snapshot).harness !== undefined;
  return {
    ...snapshot,
    summary: picked ? { ...snapshot.summary, sessionId: "", cwd: projectDraft } : { sessionId: "", cwd: projectDraft },
  } as AcpmuxSnapshot;
}

/// A page with no session yet whose Cloud start is out or failed (`cloudStart`): its composer names the folder that
/// start copies, the start's own `cwd` (cmux#46023). A New Tab page's Cloud send hands its folder to the start and
/// never to the page's `projectDraft`, so the chat composer the page gives way to read No folder beside Cloud while
/// the start copied that folder. Only the folder changes: the chips keep naming the agent and model the start sends.
/// A folderless start (`home`) has no `cwd`, and its chip still reads No folder.
export function withCloudStartFolder(snapshot: AcpmuxSnapshot, startCwd: string | undefined): AcpmuxSnapshot {
  if (!startCwd || snapshot.sessionId) return snapshot;
  return { ...snapshot, summary: { ...snapshot.summary, sessionId: "", cwd: startCwd } } as AcpmuxSnapshot;
}

/// The harness and model a pick on this sessionless page holds (a switch that has not failed), for
/// the `chat.new` that starts the chat in the picked folder: `switchTo` then carries the pick's
/// model and options there. Empty when nothing is held.
export function heldPick(snapshot: AcpmuxSnapshot): { harness?: string; model?: string } {
  const harness = snapshot.summary?.harness;
  if (snapshot.sessionId || !snapshot.switching || snapshot.switching.phase === "failed" || !harness) return {};
  const model = snapshot.summary?.model;
  return model && model !== "default" ? { harness, model } : { harness };
}
