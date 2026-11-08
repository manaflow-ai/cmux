// `/resume <ref>` (Lawrence 2026-11-07: "i paste in 920ab030-… and i want it to 'just work'"):
// the app finds the chat a pasted session id, id start, transcript path or resume command names
// (acpmux's `_acpmux/chat_resolve`) and resumes it in a workspace of its own, in its own folder,
// with no further question. A bare `/resume` opens the chats search, as before.
import type { StringKey } from "./i18n";

/// The app's answer to `chats.resume`: `opened`, or why no chat opened.
export type ResumeStatus = "opened" | "notFound" | "ambiguous" | "tooShort" | "unavailable";

type CallNative = (method: string, params?: Record<string, unknown>) => Promise<unknown>;
type Translate = (key: StringKey, values?: Record<string, string | number>) => string;

/// Runs `/resume` with `args`: bare, the chats search (`showAllChats`); with a reference, the app's
/// `chats.resume`. Resolves once the chat opens; rejects with the inline refusal otherwise, so the
/// composer keeps the draft and says why.
export function runResume(
  _args: string | undefined,
  _callNative: CallNative,
  showAllChats: () => void,
  _t: Translate,
): true | Promise<void> {
  // Red: today's /resume ignores what follows it and opens the chats search.
  showAllChats();
  return true;
}
