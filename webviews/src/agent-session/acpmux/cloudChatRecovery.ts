// Cloud chat recovery uses the native VM id and account, never a peer name. A failed list,
// sign-out, or a different team's list cannot establish that this chat's machine was deleted.
import type { ChatUnavailable } from "./chatUnavailable";

export type CloudChatIdentity = { id: string; account: (string | null)[] };
export type CloudChatState = "paused" | "deleted" | "live";

export function cloudChatState(identity: CloudChatIdentity, reply: unknown): CloudChatState | undefined {
  const value = reply as {
    signedIn?: unknown;
    loaded?: unknown;
    account?: unknown;
    machines?: unknown;
    complete?: unknown;
  } | null;
  if (
    value?.signedIn !== true ||
    value.loaded !== true ||
    !Array.isArray(value.machines) ||
    JSON.stringify(value.account) !== JSON.stringify(identity.account)
  )
    return undefined;
  if (!identity.account[0]) return undefined;
  const machine = value.machines.find((row: unknown) => (row as { id?: unknown })?.id === identity.id) as
    | { stage?: unknown }
    | undefined;
  if (!machine) return value.complete === true ? "deleted" : undefined;
  if (machine.stage === "destroyed") return "deleted";
  return machine.stage === "paused" ? "paused" : "live";
}

export function cloudChatUnavailable(
  unavailable: ChatUnavailable,
  state: CloudChatState | undefined,
  machine?: string,
): ChatUnavailable {
  const named = machine ?? ("machine" in unavailable ? unavailable.machine : undefined);
  if (state === "deleted") return { reason: "machineDeleted", ...(named ? { machine: named } : {}) };
  if (state === "paused") return { reason: "paused", ...(named ? { machine: named } : {}) };
  return unavailable;
}
