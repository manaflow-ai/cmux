// acpmux's digest of a message surge (cmux-tui acpmux surge_triage.rs `digest`): the daemon's own
// prompt that hands the chat's agent the held messages that need it, one line per thread with the
// command that reads it. While it waits in the queue its row is a labelled summary, "Held messages"
// then "29 messages in 23 threads", that opens the held threads (SurgeHoldRow.tsx), never the
// digest's raw first sentence cut at the row's end (Leo, 2026-11-23: "this looks ass idk").
//
// A queue listing names no provenance (direct/queue.ts), so the digest is known by its words, which
// only acpmux writes; a person's prompt that starts with them reads the same, and opens the same list.
import type { Translate } from "./i18n";

export type SurgeDigest = { messages: number; threads: number };

// l10n-allow: acpmux's words to the agent (surge_triage.rs `digest`), matched, never shown
const DIGEST_WORDS = /^Held during a message surge: (\d+) message\(s\) in (\d+) thread\(s\) need you\./;

/// The counts of a queued surge digest, or undefined for any other prompt.
export function surgeDigestOf(prompt: string): SurgeDigest | undefined {
  const match = DIGEST_WORDS.exec(prompt);
  if (!match) return undefined;
  return { messages: Number(match[1]), threads: Number(match[2]) };
}

/// "29 messages in 23 threads".
export function surgeDigestText(t: Translate, { messages, threads }: SurgeDigest): string {
  if (threads === 1) return messages === 1 ? t("queuedDigest.one") : t("queuedDigest.oneThread", { messages });
  return t("queuedDigest.summary", { messages, threads });
}
