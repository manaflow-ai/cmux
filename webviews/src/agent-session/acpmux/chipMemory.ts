/// The effort chip each harness's chats last showed (Leo 2026-10-13: a new chat's composer drew
/// grey bars there, then its chips). A new chat draws it at once, before its session reports, and
/// the session's own value replaces it in place. Per viewer; a missing or blocked store only leaves
/// that place empty until the session reports. The access chip names the mode acpmux starts the chat
/// in instead (`_acpmux/start_mode`, startMode.ts): the last chat's mode is not the next one's.
export type LastChips = { effort?: string };

const STORAGE_KEY = "cmux.acpmux.lastChips";

export function loadLastChips(): Record<string, LastChips> {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    return parsed && typeof parsed === "object" ? (parsed as Record<string, LastChips>) : {};
  } catch {
    return {};
  }
}

export function rememberLastChips(harness: string, chips: LastChips): void {
  try {
    const all = loadLastChips();
    const known = all[harness];
    if (known?.effort === chips.effort) return;
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify({ ...all, [harness]: chips }));
  } catch {
    // Storage unavailable: the next new chat leaves those places empty until it reports.
  }
}
