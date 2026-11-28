// A teammate's Cloud machine refused the chat start (`agent_session.team_vm_blocked`): the card
// offers to share the machine with the person, and when they may not share it, to ask its owner
// (Leo, 2026-10-31: "but what's the sharing flow? we can't simply block always. we need to be
// able to get stuff running asap.").
//
// Share with Me is `machine.share.self`: the app grants the signed-in person chats on the machine
// through cmux-platform (`PUT /v1/machines/{id}/chat-grants/{user}`, sent by the cmux-cloud-api
// crate's `machine.share_chat`), and answers. Only the machine's creator or a team admin may
// grant, and only on a team machine: anyone else gets `machine.creator_or_admin`, and the card
// then offers Ask the Owner, which copies a short request naming the machine.
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
/// error's code (the platform's refusal code, the call's failure kind, or the pane's own), never its words.
export function machineShareOutcome(result: { ok: true } | { ok: false; error: unknown }): MachineShareOutcome {
  if (result.ok) return { kind: "shared" };
  const error = result.error as { code?: unknown; message?: unknown } | undefined;
  const code = typeof error?.code === "string" ? error.code : undefined;
  switch (code) {
    case "machine.creator_or_admin":
      return { kind: "forbidden" };
    case "machine.private":
      return { kind: "failed", key: "switch.share.private" };
    // No answer from the platform: the call's failure kind (cmux-cloud-api's `Failure`).
    case "timed_out":
    case "transport":
    case "no_backend":
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

/// The request Ask the Owner copies: names the machine.
export function askOwnerRequest(t: Translate, machine: string | undefined): string {
  return machine ? t("switch.askOwner.request", { machine }) : t("switch.askOwner.requestUnnamed");
}
