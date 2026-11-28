/// The effort chip each harness's chats last showed (Leo 2026-10-13: a new chat's composer drew
/// grey bars there, then its chips). A new chat draws it at once, before its session reports, and
/// the session's own value replaces it in place. Per viewer; a missing or blocked store only leaves
/// that place empty until the session reports. The access chip names the mode acpmux starts the chat
/// in instead (`_acpmux/start_mode`, startMode.ts): the last chat's mode is not the next one's.
///
/// This Mac and Cloud (Cloud and Auto Cloud) keep apart (Leo 2026-11-28: "Keep separate saved state
/// for This Mac versus Cloud + Autocloud." "Backend option lists must not overwrite them."): a
/// Cloud chat's reported level is kept under `cloud:<harness>`, so it never repaints This Mac's next
/// chat, and This Mac's never a Cloud one's. A chat on another Mac (a peer) keeps nothing here.
export type LastChips = { effort?: string };

/// Where a chat runs, for its chip memory: this Mac, or a Cloud machine (Cloud and Auto Cloud).
export type ChipPlace = "local" | "cloud";

/// The storage key of one harness's chips in one place. This Mac's stays the bare harness id, as
/// saved before the split, so a kept level still draws after an update.
export function lastChipsKey(harness: string, place: ChipPlace): string {
  return place === "cloud" ? `cloud:${harness}` : harness;
}

const STORAGE_KEY = "cmux.acpmux.lastChips";

export function loadLastChips(): Record<string, LastChips> {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    return parsed && typeof parsed === "object" ? (parsed as Record<string, LastChips>) : {};
  } catch {
    return {};
  }
}

export function rememberLastChips(harness: string, chips: LastChips, place: ChipPlace = "local"): void {
  try {
    const all = loadLastChips();
    const key = lastChipsKey(harness, place);
    if (all[key]?.effort === chips.effort) return;
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify({ ...all, [key]: chips }));
  } catch {
    // Storage unavailable: the next new chat leaves those places empty until it reports.
  }
}
