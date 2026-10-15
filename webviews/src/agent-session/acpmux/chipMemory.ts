/// The effort and access chips each harness's chats last showed (Leo 2026-10-13: a new chat's
/// composer drew grey bars there, then its chips). A new chat draws these at once, before its
/// session reports, and the session's own values replace them in place. Per viewer; a missing or
/// blocked store only leaves those places empty until the session reports.
export type LastChips = { effort?: string; mode?: string };

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
    if (known?.effort === chips.effort && known?.mode === chips.mode) return;
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify({ ...all, [harness]: chips }));
  } catch {
    // Storage unavailable: the next new chat leaves those places empty until it reports.
  }
}
