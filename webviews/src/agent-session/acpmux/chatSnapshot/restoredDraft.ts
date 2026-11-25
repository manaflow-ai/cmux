// The prompt a restored chat's composer showed when its page last wrote its copy (``ChatSnapshot/draft``,
// kept by the host with the copy or with the reason it wrote none), for the live composer's first
// frame. After a relaunch the copy draws the composer with its draft in it, and acpmux's own draft
// read answers only once the page's connection is up (13 s on Leo's 2026-11-22 relaunch). The
// composer opened empty meanwhile, so the swap dropped the box to one line and the read grew it back
// (Leo, 2026-11-22: "composer dips down then goes back up"). The composer holds this text from its
// first frame instead, as acpmux's draft last seen, until that read answers (Composer.tsx
// `applyDraftRead`): untouched, the read's draft replaces it; typed on, what was typed stays.

/// The global the host's `__snapshot/chat.js` sets to the restored tab's chat (AgentPaneChatSnapshots.swift).
const RESTORED_CHAT = "__cmuxRestoredChat";
/// The global that script sets to the prompt the chat's composer showed, only when there was one
/// (AgentPaneChatSnapshots.swift `draftGlobal`).
const RESTORED_DRAFT = "__cmuxRestoredDraft";
/// The event that script sends once it set its globals; it loads `async`, so it can come after the
/// composer mounted.
export const RESTORED_CHAT_EVENT = "cmux-restored-chat";

/// Most of a draft a copy carries beside its markup, in UTF-16 units: a pasted log is left out
/// (the composer then opens as before), so the copy stays inside the host's bound.
export const SNAPSHOT_DRAFT_MAX_CHARS = 64 * 1024;

/// Chats whose stood-in prompt an acpmux read replaced: never drawn again on this page.
const replaced = new Set<string>();

/// The prompt the host served for chat `sessionId`, or undefined: none served, another chat's, an
/// empty prompt, or one an acpmux read of this page already answered for.
export function restoredDraft(sessionId: string | undefined): string | undefined {
  if (!sessionId || replaced.has(sessionId) || typeof window === "undefined") return undefined;
  const globals = window as unknown as Record<string, unknown>;
  if (globals[RESTORED_CHAT] !== sessionId) return undefined;
  const draft = globals[RESTORED_DRAFT];
  return typeof draft === "string" && draft.trim() ? draft : undefined;
}

/// An acpmux read of `sessionId`'s draft answered: from here the prompt is acpmux's, and a composer
/// that mounts again on this page never draws the copy's.
export function replacedRestoredDraft(sessionId: string | undefined): void {
  if (sessionId) replaced.add(sessionId);
}

/// The draft the copy (or miss) being written carries: the composer's text, or none when it is
/// empty or larger than ``SNAPSHOT_DRAFT_MAX_CHARS``.
export function snapshotDraft(text: string | undefined): string | undefined {
  return text?.trim() && text.length <= SNAPSHOT_DRAFT_MAX_CHARS ? text : undefined;
}

/// Tests: a new page.
export function resetRestoredDraftsForTests(): void {
  replaced.clear();
}
