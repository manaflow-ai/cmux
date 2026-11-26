import { createContext, useContext, useLayoutEffect } from "react";

/// How much a notice above the composer matters (hq#2569 #12): an error beats what is happening
/// now, which beats a hint, which beats an update the person started, which beats standing
/// information that is always there (the agent rules card). Higher wins.
export const NOTICE_TIER = { error: 40, status: 30, hint: 20, update: 10, info: 5 } as const;
export type NoticeTier = keyof typeof NOTICE_TIER;

/// A notice as the floating bottom stack holds it (App.tsx's notices before the composer, and the
/// host's line, HostError.tsx), by the roots the notices share: a card notice is `.acpmux-host-error`
/// (PaneNotices, SwitchNotice, InstructionsNotice, HarnessHealthNotice, RulesNotice), a line notice
/// `.acpmux-switch-notice` (AutoResumeNotice, FolderChoice, the worktree's lines, the side session's
/// failure, Sandboxed), a design-system one `.ui-notice` (PlanScopeDriftNotice). A new notice built on
/// one of them is one here. Never the composer, the asks stack, the tray or the goal: the transcript
/// measures these to lie over its foot (VirtualTranscript `noticeHold`), so no row moves as one comes.
/// The composer form draws its own remote, sign-in and blocked note inside itself, above its box
/// (Composer.tsx), so that one is matched one level down.
export const DOCK_NOTICE = `:scope > .acpmux-composer > .acpmux-composer-remote-note, :scope > :is(${[
  "acpmux-host-line",
  "acpmux-host-line-group",
  "acpmux-host-error",
  "acpmux-switch-notice",
  "ui-notice",
  "acpmux-dictation-notice",
  "acpmux-managed-banner",
  "acpmux-composer-remote-note",
]
  .map((name) => `.${name}`)
  .join(", ")})`;

export type Entry = { tier: number; order: number };
type Slot = {
  shown: string | undefined;
  claim(id: string, tier: number): void;
  release(id: string): void;
};

export const SlotContext = createContext<Slot | undefined>(undefined);

/// The notice that draws: the highest tier, then the one that asked first.
export function topNotice(entries: ReadonlyMap<string, Entry>): string | undefined {
  let best: [string, Entry] | undefined;
  for (const entry of entries) {
    const [, value] = entry;
    if (!best || value.tier > best[1].tier || (value.tier === best[1].tier && value.order < best[1].order))
      best = entry;
  }
  return best?.[0];
}

/// A notice's turn in the slot: `wants` says it has something to show; `shown` is whether it
/// draws now. The claim lands in a layout effect, so a lower notice never paints under a higher one.
export function useNoticeTurn(id: string, tier: NoticeTier, wants: boolean): { shown: boolean } {
  const slot = useContext(SlotContext);
  const rank = NOTICE_TIER[tier];
  const claim = slot?.claim;
  const release = slot?.release;
  useLayoutEffect(() => {
    if (!claim || !release) return;
    if (wants) claim(id, rank);
    else release(id);
  }, [claim, release, id, rank, wants]);
  useLayoutEffect(() => () => release?.(id), [release, id]);
  if (!slot) return { shown: wants };
  return { shown: wants && slot.shown === id };
}
