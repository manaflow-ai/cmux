// `/resume <ref>` (Lawrence 2026-11-07: "i paste in 920ab030-… and i want it to 'just work'"):
// the app finds the chat a pasted session id, id start, transcript path or resume command names
// (acpmux's `_acpmux/chat_resolve`) and resumes it in a workspace of its own, in its own folder,
// with no further question. A bare `/resume` opens the chats search, as before.
import { CmuxCommandRefused } from "./cmuxCommands";
import type { StringKey } from "./i18n";

/// The app's answer to `chats.resume`: `opened`, or why no chat opened.
export type ResumeStatus = "opened" | "notFound" | "ambiguous" | "tooShort" | "unavailable";

type CallNative = (method: string, params?: Record<string, unknown>) => Promise<unknown>;
type Translate = (key: StringKey, values?: Record<string, string | number>) => string;

/// The refusal the composer shows for each status but `opened`.
const REFUSALS: Record<Exclude<ResumeStatus, "opened">, StringKey> = {
  notFound: "composer.cmuxResumeNotFound",
  ambiguous: "composer.cmuxResumeAmbiguous",
  tooShort: "composer.cmuxResumeTooShort",
  unavailable: "composer.cmuxResumeUnavailable",
};

/// Runs `/resume` with `args`: bare, the chats search (`showAllChats`); with a reference, the app's
/// `chats.resume`. Resolves once the chat opens; rejects with the inline refusal otherwise, so the
/// composer keeps the draft and says why.
export function runResume(
  args: string | undefined,
  callNative: CallNative,
  showAllChats: () => void,
  t: Translate,
): true | Promise<void> {
  const ref = args?.trim() ?? "";
  if (!ref) {
    showAllChats();
    return true;
  }
  return callNative("chats.resume", { ref }).then(
    (reply) => {
      const status = (reply as { status?: unknown } | null)?.status;
      if (status === "opened") return;
      const key = REFUSALS[status as keyof typeof REFUSALS] ?? REFUSALS.unavailable;
      throw new CmuxCommandRefused(t(key, { ref: shown(ref) }));
    },
    (error: unknown) => {
      if (error instanceof CmuxCommandRefused) throw error;
      throw new CmuxCommandRefused(t(REFUSALS.unavailable, { ref: shown(ref) }));
    },
  );
}

/// A long pasted path reads as its file name in the refusal.
function shown(ref: string): string {
  const name = ref.split("/").at(-1) || ref;
  return name.length > 48 ? `${name.slice(0, 47)}…` : name;
}
