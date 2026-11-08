// Triage (wow idea 22): from anywhere, Ctrl-Cmd-; opens the chat that has waited longest on the
// person, and Ctrl-Cmd-Y answers the chat on screen, then the app opens the next one
// (CmuxNextAgentLanes AgentTriage). The app sends the chat on screen `triageAnswer`; this says
// what it does there, and the strip above the ask (TriageStrip.tsx) says it before the key is
// pressed. Every answer goes the way a click on the ask goes: a tool permission or a plan is
// allowed once through its card's own Allow once (the ⌥⌘1 event), never for the chat; a question
// takes its first choice through Needs you's one-click answer. An ask a key cannot answer (several
// questions, a typed answer) stays waiting, and the key only moves on.
import type { AcpmuxPermission } from "../model";
import { permissionAnswers } from "../permissions/prompt";
import type { PermissionClientState } from "../permissions/protocol";
import { askItemId, questionAnswers, type NeedsYouAnswer, type NeedsYouItem } from "./model";

export type TriageMove =
  /// The card's Allow once (a plan's Approve plan).
  | { kind: "allow"; plan: boolean }
  /// A question's first choice, as its Needs you row answers it in one click.
  | { kind: "choice"; item: NeedsYouItem; answer: NeedsYouAnswer }
  /// Nothing a key can send: the chat stays waiting.
  | { kind: "skip" };

/// What `triageAnswer` does for this chat: its ask `permission` (the one its single card shows, never
/// one a group holds), else a
/// pending permission group (whose panel takes the same Allow once event); undefined when nothing
/// waits here. A question's first choice comes from its Needs you row, else from the question
/// itself, so it works with the Needs you list turned off.
export function triageMove(
  permission:
    | (Pick<AcpmuxPermission, "permissionId" | "question" | "plan"> &
        Partial<Pick<AcpmuxPermission, "options">>)
    | undefined,
  items: readonly NeedsYouItem[],
  sessionId?: string,
  groups?: Pick<PermissionClientState, "supported" | "groups" | "allowRefused">,
): TriageMove | undefined {
  if (!permission) {
    const pending =
      groups?.supported && !groups.allowRefused
        ? groups.groups.some(
            (group) => group.state === "pending" && group.decisions.includes("allow_once"),
          )
        : false;
    return pending ? { kind: "allow", plan: false } : undefined;
  }
  // The card's own Allow once (permissionAnswers): an ask that offers none is only skipped. While a
  // permission group waits, its panel takes the Allow once event and the card's keys are off
  // (permissionKeys.ts `cardTakesShortcuts`): the key would answer the group, not this ask, so it
  // only moves on.
  const panelKeys =
    groups?.supported && groups.groups.some((group) => group.state === "pending" || group.state === "collecting");
  if (!permission.question && panelKeys) return { kind: "skip" };
  if (!permission.question)
    return permissionAnswers(permission.options ?? []).allowOnce
      ? { kind: "allow", plan: Boolean(permission.plan) }
      : { kind: "skip" };
  const listed = items.find((each) => each.id === askItemId(permission.permissionId));
  const item: NeedsYouItem | undefined =
    listed ??
    (sessionId
      ? {
          id: askItemId(permission.permissionId),
          kind: "decision",
          sessionId,
          ask: "",
          who: { name: "", chief: false },
          answers: questionAnswers(permission.question),
          permissionId: permission.permissionId,
          question: permission.question,
        }
      : undefined);
  const answer = item?.answers[0];
  return item && answer ? { kind: "choice", item, answer } : { kind: "skip" };
}

/// How many other chats wait on the person: one per chat, never this one or a marked tab.
export function othersWaiting(
  items: readonly NeedsYouItem[],
  sessionId: string | undefined,
): number {
  const chats = new Set<string>();
  for (const item of items)
    if (item.kind !== "tab" && item.sessionId && item.sessionId !== sessionId)
      chats.add(item.sessionId);
  return chats.size;
}

/// When this chat's ask was first seen waiting (epoch ms), for the strip's age.
export function askedAt(
  permission: Pick<AcpmuxPermission, "permissionId"> | undefined,
  items: readonly NeedsYouItem[],
) {
  return permission
    ? items.find((each) => each.id === askItemId(permission.permissionId))?.at
    : undefined;
}
