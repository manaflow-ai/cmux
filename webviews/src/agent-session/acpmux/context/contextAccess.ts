import type { AcpmuxSnapshot } from "../model";
import type { ContextOverride } from "./ContextScreen";

/// The client call a Context save goes through (`AcpmuxDirectClient.setContextOverride`).
export type ContextOverrideClient = {
  setContextOverride(change: ContextOverride, sessionId?: string): Promise<unknown>;
};

/// Whether this connection may open the shown chat's Context screen (Session Info's View Prompt)
/// and save or reset its guidance. acpmux hands cmux's prompt text and its editing only to this
/// Mac's app (server/requests/context.rs), and a chat on another machine reaches it through the
/// daemon's `agent-session-context`, which admits only the owner's carrier. Of the app's remote
/// wires only the owner's attach carries `ownerCloud` (the Cloud API said the signed-in caller
/// owns the machine): an observation never does (AgentTabRemoteHost passes it to an attach only),
/// and a teammate or link guest does not own the machine. Any other origin gets no Context.
export function contextAccess(snapshot: Pick<AcpmuxSnapshot, "origin" | "ownerCloud" | "sessionId">): boolean {
  if (!snapshot.sessionId) return false;
  return snapshot.origin === "local" || (snapshot.origin === "remote" && snapshot.ownerCloud === true);
}

/// The Context screen's save for the chat `sessionId`, or undefined where this connection may not
/// edit (the screen then shows its guidance read-only). The call runs in the Save or Use Default
/// click with no await before it: the relay takes an edit only on the person's gesture.
export function contextSave(
  snapshot: Pick<AcpmuxSnapshot, "origin" | "ownerCloud" | "sessionId">,
  client: ContextOverrideClient | null | undefined,
  sessionId: string | undefined,
): ((change: ContextOverride) => Promise<unknown>) | undefined {
  if (!client || !sessionId || !contextAccess(snapshot)) return undefined;
  return (change) => client.setContextOverride(change, sessionId);
}
