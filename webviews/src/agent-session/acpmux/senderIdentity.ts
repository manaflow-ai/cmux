import type { AcpmuxSessionEntry } from "./sessionList";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import type { IncomingRelation } from "./conversation/incomingMessage";

export type SenderReference = {
  name: string;
  sessionId?: string;
  relation?: IncomingRelation;
  /** The sender's given name as its message carried it (acpmux `fromDisplayName`). */
  displayName?: string;
};
/** `icon`: the icon the chat set (acpmux `icon`); `formerNames`: its names before its renames,
 *  oldest first, for a "fka" line. */
export type SenderIdentity = SenderReference & {
  harness?: string;
  host?: string;
  icon?: HarnessIconSpec;
  formerNames?: string[];
  known: boolean;
};

/** Strip only the peer prefix the session metadata identifies. A slash alone proves no host. */
export function senderSessionName(name: string, peer?: string): string {
  const value = name.trim();
  const host = peer?.trim();
  return host && value.startsWith(`${host}/`) ? value.slice(host.length + 1).trim() : value;
}

/** The session list is authoritative for names, harnesses and parentage; message prose is not. */
export function resolveSenderIdentity(
  sender: SenderReference,
  entry?: AcpmuxSessionEntry,
  viewerSessionId?: string,
): SenderIdentity {
  const parent = entry?.startedBy ?? entry?.spawnedBy;
  const relation =
    sender.relation ??
    (sender.sessionId === entry?.sessionId && viewerSessionId && parent === viewerSessionId ? "subsession" : undefined);
  // A given name reads first (Leo, 2026-11-23: "the send/recieve messages are still only the
  // older names"): the listed chat's own, else the one its message carried.
  // The name it was given ("Mango", acpmux `displayName`) is the one every surface shows.
  const name =
    entry?.displayName?.trim() ||
    sender.displayName?.trim() ||
    senderSessionName(entry?.shortName ?? "", entry?.peer) ||
    senderSessionName(entry?.name ?? "", entry?.peer) ||
    senderSessionName(sender.name, entry?.peer);
  // Older session summaries omitted hostKind. Keep their host as remote evidence, while an
  // explicitly local entry remains unlabeled (the same rule as sessionList.cloudHost).
  const host = entry?.peer ?? (entry?.hostKind === "local" ? undefined : entry?.host);
  return {
    name,
    known: entry !== undefined || sender.sessionId !== undefined,
    ...(sender.sessionId && { sessionId: sender.sessionId }),
    ...(entry?.sessionId && { sessionId: entry.sessionId }),
    ...(entry?.harness && { harness: entry.harness }),
    ...(entry?.icon && { icon: entry.icon }),
    ...(entry?.formerNames?.length && { formerNames: entry.formerNames }),
    ...(host && { host }),
    ...(relation && { relation }),
  };
}
