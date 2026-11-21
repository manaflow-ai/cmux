import { harnessFamily } from "./agentRuns";
import type { SenderIconBadge } from "./senderIconLook";

/// The type label is already established by a list heading or a harness mark. Keep it out of
/// every row so the mark carries the identity instead of repeating "Subagent".
export function isRepeatedAgentKind(kind: string | undefined): boolean {
  return !!kind && /^(?:sub[ -]?agent|sub[ -]?session|agent)$/iu.test(kind.trim());
}

/// A subagent's own mark when no harness is known: never the chat bubble (`agent.session`) its
/// parent chat and every session list draw (Leo, 2026-10-28: "Shouldn't the subagent icon be
/// different?").
export const SUBAGENT_FALLBACK = "task.ai";

/// The harness mark a subagent's row draws: only one of another model family than its chat's (a
/// Codex subagent under Claude). One of the chat's own family draws the subagent mark in its own
/// tone instead, so a list of them tells apart, never the same Claude mark on every line (Leo,
/// 2026-11-04: "didn't we see better stacked subagents or whatever earlier idk these all being
/// claude"; 2026-10-29: "one of these is Codex, one of these is Claude"). While sender icons wear a
/// session badge (senderIconLook.ts), every subagent shows its family's mark and the badge in its
/// tone tells them apart (Leo, 2026-11-05: "we ought to just have it be the model family's icon").
export function foreignHarness(
  harness: string | undefined,
  chatHarness: string | undefined,
  /// The look's badge (`useSenderIconLook().badge`), read by the caller's render so a change of the
  /// setting draws the row again.
  badge: SenderIconBadge,
): string | undefined {
  if (!harness) return undefined;
  if (badge !== "none") return harness;
  return chatHarness && harnessFamily(harness) === harnessFamily(chatHarness) ? undefined : harness;
}
