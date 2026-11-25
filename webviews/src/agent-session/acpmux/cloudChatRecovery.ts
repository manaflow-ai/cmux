// Cloud chat recovery uses the native VM id and account, never a peer name. A failed list,
// sign-out, or a different team's list cannot establish that this chat's machine was deleted.
// Failed stages may still be paused; native attach resumes or reconnects either way.
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
  return machine.stage === "paused" || machine.stage === "failed" ? "paused" : "live";
}

export function cloudChatUnavailable(
  unavailable: ChatUnavailable,
  state: CloudChatState | undefined,
  machine?: string,
  resuming = false,
): ChatUnavailable {
  const named = machine ?? ("machine" in unavailable ? unavailable.machine : undefined);
  if (state === "deleted") return { reason: "machineDeleted", ...(named ? { machine: named } : {}) };
  // A resume the person asked for keeps its card, spinner and all, from the click until the chat opens:
  // the machine reading live before its chat attaches no longer swaps the card for a blank page or
  // "Reconnecting…" for a moment (cmux#55066: "a resume this machine weird thing").
  // Only while the chat itself is just not reached yet: a definitive answer (deleted, not found) wins.
  const stillReaching = unavailable.reason === "offline" || unavailable.reason === "connecting";
  if (state === "paused" || (resuming && state === "live" && stillReaching))
    return { reason: "paused", ...(named ? { machine: named } : {}) };
  return unavailable;
}

// A disconnected native wire may never reach sessions.list. Its empty selected chat can show
// recovery, but a cached transcript stays visible through transient transport failures.
export function cloudChatRecoveryActive(
  unavailable: boolean,
  session: string | undefined,
  rowCount: number,
  connected: boolean,
  freshView = false,
): boolean {
  return unavailable || (!freshView && !!session && rowCount === 0 && !connected);
}
