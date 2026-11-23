import type { AcpmuxSnapshot } from "./model";
import { type StringKey, type Translate } from "./i18n";
import { relativeTime } from "./conversation/relativeTime";
import { isAgentHome, projectLabel } from "./sessionList";

/// Empty-state copy: keys of the pane's string table.
export const EMPTY_STATE_LABELS = {
  prompt: "empty.prompt",
  /// `{project}` is replaced by the session's folder name, drawn underlined.
  promptIn: "empty.promptIn",
} as const satisfies Record<string, StringKey>;

/// The hero's folder: the sidebar's project label, or nothing for no folder or the home folder.
export function projectName(cwd: string | undefined): string | undefined {
  if (!cwd?.replace(/\/+$/, "") || isAgentHome(cwd)) return undefined;
  const label = projectLabel(cwd);
  return label === "~" ? undefined : label;
}

/// A new chat has no turns, rows or queued work. The host can identify an unsent
/// chat before a summary exists; attached chats use their own session's summary.
/// A daemon that doesn't count turns still exposes older history for an old session.
export function isNewChat(snapshot: AcpmuxSnapshot, newSession = false): boolean {
  const summary = snapshot.summary;
  // The host knows a direct chat is new before an agent can produce a summary.
  // Keep its conversion and project controls usable while that agent starts.
  if (newSession && !summary && !snapshot.sessionId && !snapshot.canLoadOlder)
    return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0;
  // A harness switch's new chat has no session yet; its summary is the one the switch draws.
  if (!summary || (summary.sessionId !== snapshot.sessionId && !snapshot.switching)) return false;
  // While connecting or reconnecting, a chat its summary says has no turns is still new: it keeps
  // its hero (the page's cached chat, the chat before the drop) instead of a blank transcript.
  if (snapshot.connection.startsWith("failed")) return false;
  const turns = summary.turnCount ?? (snapshot.canLoadOlder ? 1 : 0);
  return snapshot.rows.length === 0 && !snapshot.isWorking && snapshot.queue.length === 0 && turns === 0;
}

/// A quiet start under a new chat's hero (EmptyState.tsx): `id` keys it, `time` is how old its
/// source is (none for a start with no source chat).
export type EmptyStateStart = {
  id: string;
  label: string;
  time?: string;
  onPick(): void;
};

/// A new chat's quiet starts, at most three. The last prompt in this folder and the pull request
/// review only fill the composer: the person reads the words and sends them (a past prompt can be
/// "merge it" or "delete the branch", which must never replay on one click).
export function contextualStarts({
  folder,
  sessions,
  pullRequest,
  tour,
  prefill,
  t,
  now,
  language,
}: {
  folder: string;
  sessions: readonly { cwd?: string; recentPrompt?: string; updatedAt?: number }[];
  pullRequest?: number;
  tour?: { label: string; onTake(): void };
  prefill(text: string): void;
  t: Translate;
  now: number;
  language?: string;
}): EmptyStateStart[] {
  const bare = (path: string) => path.replace(/(.)\/+$/, "$1");
  const last = sessions
    .filter((session) => session.cwd && bare(session.cwd) === bare(folder) && session.recentPrompt?.trim())
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0];
  const starts: EmptyStateStart[] = [];
  if (last?.recentPrompt) {
    const prompt = last.recentPrompt;
    starts.push({
      id: "last-prompt",
      label: prompt,
      ...(last.updatedAt ? { time: relativeTime(last.updatedAt, now, language) } : {}),
      onPick: () => prefill(prompt),
    });
  }
  if (pullRequest) {
    starts.push({
      id: "review-pull-request",
      label: t("emptyState.reviewPullRequest", { number: pullRequest }),
      onPick: () => prefill(t("emptyState.reviewPullRequestPrompt", { number: pullRequest })),
    });
  }
  if (tour) starts.push({ id: "tour", label: tour.label, onPick: tour.onTake });
  return starts.slice(0, 3);
}
