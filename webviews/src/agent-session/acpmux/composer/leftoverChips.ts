// A held prompt given back with no composer to take it (a new chat in another folder by then) leaves
// its words in the host's new-chat draft (pane/draftHost.ts `newChatDraft.kept`), which keeps text
// only. Its images are kept beside it under the tab's own key in the host's chip store (the one every
// chat's unsent chips use, AgentPaneDraftAttachments.swift: any key is a folder of its own), and the
// tab's next new-chat composer takes them back with the words (Leo, 2026-11-25: "wait that message
// got split up and queued": a message and its images are one prompt on every hand-back path).
import type { ComposerAttachment } from "../attachments";
import { keepElsewhere, keptChips, type KeptAttachments } from "./keptAttachments";

/// The store key of tab `tab`'s leftover chips.
export const leftoverKey = (tab: string): string => `new-tab-leftover:${tab}`;

/// Adds `chips` to what tab `tab` already left.
export const keepLeftoverChips = (store: KeptAttachments, tab: string, chips: readonly ComposerAttachment[]) =>
  chips.length ? keepElsewhere(store, leftoverKey(tab), keptChips(chips)) : Promise.resolve();

/// What tab `tab` left, taken once: the store holds none after.
export async function takeLeftoverChips(store: KeptAttachments, tab: string): Promise<ComposerAttachment[]> {
  const kept = await store.read(leftoverKey(tab)).catch(() => []);
  if (!kept.length) return [];
  await store.write(leftoverKey(tab), []).catch(() => undefined);
  return kept;
}
