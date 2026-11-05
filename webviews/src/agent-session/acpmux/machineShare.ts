// A teammate's Cloud machine refused the chat start (`agent_session.team_vm_blocked`): the card
// offers to share the machine with the person, and when they may not share it, to ask its owner
// (Leo, 2026-10-31: "but what's the sharing flow? we can't simply block always. we need to be
// able to get stuff running asap.").
//
// Share with Me is `machine.share.self`: the app grants the signed-in person chats on the machine
// through the classic Cloud API (`PUT /api/vm/{id}/chat-grants/{userId}`, web/services/vms/
// chatGrants.ts), renews the machine's link so its attach answer says `owner`, and answers. Only
// the machine's creator or a team admin may grant; anyone else gets `vm_chat_share_forbidden`,
// and the card then offers Ask the Owner, which copies a short request naming the machine.
import type { StringKey, Translate } from "./i18n";

/// Whether a refusal's card offers Share with Me (and, once refused, Ask the Owner).
export function offersMachineShare(code: string | undefined): boolean {
  return code === "agent_session.team_vm_blocked";
}

/// How Share with Me went: shared (the card retries the start), refused because only the
/// creator or an admin shares (the card offers Ask the Owner), or failed with a line to show.
export type MachineShareOutcome =
  | { kind: "shared" }
  | { kind: "forbidden" }
  | { kind: "failed"; key: StringKey; reason?: string };

/// The outcome of the native `machine.share.self` call: its reply, or what it threw. Keyed on the
/// error's code (the Cloud API's `error`, or the pane's own), never its words.
export function machineShareOutcome(result: { ok: true } | { ok: false; error: unknown }): MachineShareOutcome {
  if (result.ok) return { kind: "shared" };
  const error = result.error as { code?: unknown; message?: unknown } | undefined;
  const code = typeof error?.code === "string" ? error.code : undefined;
  switch (code) {
    case "vm_chat_share_forbidden":
      return { kind: "forbidden" };
    case "vm_chat_grants_personal_machine":
      return { kind: "failed", key: "switch.share.personal" };
    case "vm_chat_grants_unavailable":
      return { kind: "failed", key: "switch.share.unavailable" };
    default: {
      const reason = typeof error?.message === "string" && error.message.trim() ? error.message.trim() : undefined;
      return { kind: "failed", key: "switch.share.failed", ...(reason && { reason }) };
    }
  }
}

/// Runs Share with Me through `call` (the pane's native call) and maps the answer.
export async function shareMachineWithMe(call: () => Promise<unknown>): Promise<MachineShareOutcome> {
  try {
    await call();
    return machineShareOutcome({ ok: true });
  } catch (error) {
    return machineShareOutcome({ ok: false, error });
  }
}

/// The request Ask the Owner copies: names the machine and the menu item that shares it.
export function askOwnerRequest(t: Translate, machine: string | undefined): string {
  return machine ? t("switch.askOwner.request", { machine }) : t("switch.askOwner.requestUnnamed");
}
