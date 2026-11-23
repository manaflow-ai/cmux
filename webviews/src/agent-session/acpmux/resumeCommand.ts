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

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const QUOTES = /^["'`<]+|["'`>]+$/g;

/// The chat New Tab's text names to resume (user 2026-11-20: "resuming claude sessions needs to
/// 'just work'"): `/resume <ref>` (any reference acpmux's `_acpmux/chat_resolve` reads), a pasted
/// session id alone, or the harness's own resume command (`claude --resume <id>`, `claude -r <id>`,
/// `codex resume <id>`, other flags anywhere). Undefined for anything else: a bare `/resume` (the
/// slash menu's row opens the chats search), prose that mentions an id, more than one line.
export function resumeReference(text: string): string | undefined {
  const trimmed = text.trim();
  if (!trimmed || /[\r\n]/.test(trimmed)) return undefined;
  const slash = /^\/resume\s+(.+)$/i.exec(trimmed);
  if (slash) return slash[1]!.trim();
  const bare = trimmed.replace(QUOTES, "");
  if (SESSION_ID.test(bare)) return bare;
  const words = trimmed.split(/\s+/);
  const program = words[0]!.toLowerCase();
  const id = (word: string | undefined) => {
    const unquoted = word?.replace(QUOTES, "");
    return unquoted && SESSION_ID.test(unquoted) ? unquoted : undefined;
  };
  if (program === "claude") {
    for (let at = 1; at < words.length; at += 1) {
      const word = words[at]!;
      const inline = /^--resume=(.+)$/.exec(word);
      if (inline) return id(inline[1]);
      if (word === "--resume" || word === "-r") return id(words[at + 1]);
    }
    return undefined;
  }
  if (program === "codex" && words[1] === "resume") return words.slice(2).map(id).find(Boolean);
  return undefined;
}

/// How the Resume row names its reference: a session id's first block, a path's file name.
export function shownResumeReference(ref: string): string {
  if (SESSION_ID.test(ref)) return `${ref.slice(0, 8)}…`;
  return shown(ref);
}

/// A long pasted path reads as its file name in the refusal.
function shown(ref: string): string {
  const name = ref.split("/").at(-1) || ref;
  return name.length > 48 ? `${name.slice(0, 47)}…` : name;
}
