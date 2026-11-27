import type { AcpmuxSnapshot } from "../model";

/// A page with no session yet, after a folder pick (`projectDraft`): its composer names that folder.
/// A pick already made on the page (a switch holds its harness, model and options) stays: a
/// folder pick never puts the chips back on a default (Leo 2026-10-18). With no pick, the summary
/// names only the folder, so the chips name what a chat there starts on.
export function withDraftFolder(snapshot: AcpmuxSnapshot, projectDraft: string | undefined): AcpmuxSnapshot {
  if (projectDraft === undefined || snapshot.sessionId) return snapshot;
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

/// The agent and model a Cloud start runs, on the composer while the start shows in place of a chat that has none
/// (a page with no session, or the empty local chat it replaces): the model chip names what was sent (cmux#45774).
export function withCloudStartPick(snapshot: AcpmuxSnapshot, pick: CloudStartPick | undefined): AcpmuxSnapshot {
  if (!pick) return snapshot;
  return {
    ...snapshot,
    summary: { ...snapshot.summary, harness: pick.harness, ...(pick.model ? { model: pick.model } : {}) },
  } as AcpmuxSnapshot;
}

/// The agent and model a Cloud start sent, and what the chat under it named then (`over`: its own summary, before
/// the start's pick covered it).
export type CloudStartPick = { harness: string; model?: string; over?: { harness?: string; model?: string } };

/// retry-prompt-ok: a Cloud start's Retry sends the prompt again (a paid model request on a Cloud machine).
/// The pick a Cloud start shows on the composer, so the chip names it and a Retry sends it again. While the start
/// runs, always. Once it failed, until the person picks again: a New Tab's pick lives only in the start (the chat
/// under it names no agent), so dropping it on failure retried as the first installed agent, and a pick made since
/// (the chat's own harness or model no longer what it was) goes with the next send instead (#46874 review).
export function shownCloudStartPick(
  shown: boolean,
  start: { state: "starting" | "failed"; pick?: CloudStartPick } | undefined,
  current: { harness?: string; model?: string },
): CloudStartPick | undefined {
  const pick = shown ? start?.pick : undefined;
  if (!pick || start?.state === "starting") return pick;
  const over = pick.over ?? {};
  return over.harness === current.harness && over.model === current.model ? pick : undefined;
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
