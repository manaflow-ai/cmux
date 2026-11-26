// Each conversation's place on the chat detail ladder, the same four levels the agent chat's menu
// has (agent-session/acpmux/chatDetail.ts): Messages, Normal, Thinking, Verbose. Home Channels starts
// at Messages; a pick is this conversation's only (localStorage `cmux.home.detail`). The old
// Messages | Transcript choice (`cmux.home.presentation:<id>`) still reads: Transcript is Normal.
import { useSyncExternalStore } from "react";
import { CHAT_DETAILS, isChatDetail, type ChatDetail } from "../../agent-session/acpmux/chatDetail";
import type { Strings } from "../shared/i18n";

export type { ChatDetail } from "../../agent-session/acpmux/chatDetail";

const STORAGE_KEY = "cmux.home.detail";
const LEGACY_PREFIX = "cmux.home.presentation:";
/// The conversations whose own level is kept; the oldest choice goes first.
const LIMIT = 200;
/// Home Channels is the Chief's minimalist surface: it starts at Messages.
const DEFAULT_DETAIL: ChatDetail = "messages";

const listeners = new Set<() => void>();
/// Choices storage refused: this page keeps them for its lifetime.
const fallback = new Map<string, ChatDetail>();

function storedMap(): Record<string, unknown> {
  const value = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? "null") as unknown;
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

export function readDetail(conversation?: string): ChatDetail {
  if (!conversation) return DEFAULT_DETAIL;
  const kept = fallback.get(conversation);
  if (kept) return kept;
  try {
    if (typeof window === "undefined") return DEFAULT_DETAIL;
    const own = storedMap()[conversation];
    if (isChatDetail(own)) return own;
    return window.localStorage.getItem(LEGACY_PREFIX + conversation) === "transcript" ? "normal" : DEFAULT_DETAIL;
  } catch {
    return DEFAULT_DETAIL;
  }
}

export function setDetail(conversation: string, level: ChatDetail): void {
  try {
    const map = storedMap();
    delete map[conversation];
    map[conversation] = level;
    const keys = Object.keys(map);
    for (const key of keys.slice(0, Math.max(0, keys.length - LIMIT))) delete map[key];
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
    // The new map wins; the old key is no longer needed.
    window.localStorage.removeItem(LEGACY_PREFIX + conversation);
    fallback.delete(conversation);
  } catch {
    // Storage can be unavailable; the choice still works for this page's lifetime.
    fallback.set(conversation, level);
  }
  for (const listener of listeners) listener();
}

/// Test reset: every conversation starts at Messages again.
export function resetDetails(): void {
  fallback.clear();
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Nothing stored.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  const changed = (event: StorageEvent) => {
    if (event.key === null || event.key === STORAGE_KEY || event.key.startsWith(LEGACY_PREFIX)) listener();
  };
  window.addEventListener("storage", changed);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", changed);
  };
}

export function useDetail(conversation?: string): ChatDetail {
  return useSyncExternalStore(
    subscribe,
    () => readDetail(conversation),
    // Static renders (tests, galleries) read storage the same way; readDetail survives no window.
    () => readDetail(conversation),
  );
}

export function DetailToggle({ conversation, strings }: { conversation: string; strings: Strings }) {
  const detail = useDetail(conversation);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="lg-presentation" role="group" aria-label={strings.t("presentation.label")}>
      {CHAT_DETAILS.map((value) => (
        <button
          key={value}
          type="button"
          aria-pressed={detail === value}
          onClick={() => setDetail(conversation, value)}
        >
          {strings.t(`detail.${value}`)}
        </button>
      ))}
    </div>
  );
}
