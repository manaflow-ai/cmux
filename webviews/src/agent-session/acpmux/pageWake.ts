// What a chat page holds that acpmux does not (AgentPaneWakeState.swift), as the host hands it back. A hidden
// chat's page lets go and the tab keeps that state. It comes back on one of two paths: with the handshake of a
// page built for the chat (`wake`), or with the adopt event of a prewarmed page that takes the chat (decision
// 2026-11-16, newtab/adoption.ts; before, only a new page's handshake could hand it back, so a chat selected again
// loaded cold). One function reads it and one function applies it, for both paths.
import type { ComposerWake } from "./Composer";
import { readWakeFolds, type PaneFolds } from "./conversation/wakeFolds";
import type { ScrollAnchor } from "./VirtualTranscript";

/// A woken state as the page reads it. `scrollAnchor`: the transcript's place, null at its latest message,
/// undefined when unknown.
export type PageWake = {
  composer: ComposerWake;
  scrollAnchor?: ScrollAnchor | null;
  subagentDrafts?: unknown;
  folds?: unknown;
};

/// The host's `wake` (the handshake's field, the adopt event's field); undefined when it is no state.
export function readWake(value: unknown): PageWake | undefined {
  if (!value || typeof value !== "object") return undefined;
  const wake = value as {
    attachments?: unknown;
    shell?: unknown;
    shellText?: unknown;
    scrollAnchor?: unknown;
    atLatest?: unknown;
    subagentDrafts?: unknown;
    folds?: unknown;
  };
  const anchor = wake.scrollAnchor as { rowId?: unknown; offset?: unknown } | null | undefined;
  return {
    composer: {
      attachments: Array.isArray(wake.attachments) ? (wake.attachments as ComposerWake["attachments"]) : undefined,
      shell: wake.shell === true,
      shellText: typeof wake.shellText === "string" ? wake.shellText : undefined,
    },
    scrollAnchor:
      typeof anchor?.rowId === "string" && typeof anchor.offset === "number"
        ? { rowId: anchor.rowId, offset: anchor.offset }
        : wake.atLatest === true
          ? null
          : undefined,
    subagentDrafts: wake.subagentDrafts,
    folds: wake.folds,
  };
}

/// Where the parts of a woken state go in the page (App.tsx gives them).
export type WakeTargets = {
  /// The subagents' unsent prompts (subagents/subagentDrafts.ts `wakeIntoSubagentDrafts`).
  subagentDrafts(drafts: unknown): void;
  /// The chat's composer, null while none is mounted (a prewarmed page shows its New Tab screen).
  composer(): { wake(state: ComposerWake): void } | null;
  /// Keeps the composer's part until a composer mounts.
  holdForComposer(state: ComposerWake): void;
  /// Chat `session`'s open folds.
  folds(session: string, folds: PaneFolds): void;
  /// Chat `session`'s place as the released page left it, null at its latest message: the host keeps it
  /// with the tab, for a relaunch too.
  place(session: string, anchor: ScrollAnchor | null): void;
};

/// Puts `wake` back into the page of chat `sessionId`, for both paths. The composer's part goes to the mounted
/// composer, or waits for its mount. The folds are the chat's own or none (`readWakeFolds`). The released page's
/// place is newer than the kept one (a scroll that settled while the page was hidden was never reported), so the
/// host is told. The caller opens the transcript at `wake.scrollAnchor`.
export function applyWake(wake: PageWake, sessionId: string | undefined, to: WakeTargets): void {
  // Each subagent's unsent prompt comes back before its pane's composer reads it.
  to.subagentDrafts(wake.subagentDrafts);
  const composer = to.composer();
  if (composer) composer.wake(wake.composer);
  else to.holdForComposer(wake.composer);
  if (!sessionId) return;
  const folds = readWakeFolds(wake.folds, sessionId);
  if (folds) to.folds(sessionId, folds);
  if (wake.scrollAnchor !== undefined) to.place(sessionId, wake.scrollAnchor);
}
