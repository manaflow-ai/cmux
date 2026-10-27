import type { AcpmuxSessionEntry } from "./sessionList";
import type { IncomingRelation } from "./conversation/incomingMessage";

export type SenderReference = { name: string; sessionId?: string; relation?: IncomingRelation };
export type SenderIdentity = SenderReference & { harness?: string; host?: string; known: boolean };

/** Strip only the peer prefix the session metadata identifies. A slash alone proves no host. */
export function senderSessionName(name: string, peer?: string): string {
  const value = name.trim();
  return peer && value.startsWith(`${peer}/`) ? value.slice(peer.length + 1) : value;
}

/** The session list is authoritative for names, harnesses and parentage; message prose is not. */
export function resolveSenderIdentity(
  sender: SenderReference,
  entry?: AcpmuxSessionEntry,
  viewerSessionId?: string,
): SenderIdentity {
  const parent = entry?.startedBy ?? entry?.spawnedBy;
  const relation = sender.relation ?? (viewerSessionId && parent === viewerSessionId ? "subsession" : undefined);
  const name = entry?.shortName?.trim() || senderSessionName(entry?.name || sender.name, entry?.peer);
  const host = entry?.peer || (entry?.hostKind === "cloud" ? entry.host : undefined);
  return {
    name,
    known: entry !== undefined || sender.sessionId !== undefined,
    ...(sender.sessionId && { sessionId: sender.sessionId }),
    ...(entry?.sessionId && { sessionId: entry.sessionId }),
    ...(entry?.harness && { harness: entry.harness }),
    ...(host && { host }),
    ...(relation && { relation }),
  };
}
