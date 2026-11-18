import { useCallback, useEffect, useInsertionEffect, useRef, type RefObject } from "react";
import type { AcpmuxDirectClient } from "./direct";
import type { TrustSource } from "./folderTrust";
import type { AcpmuxSnapshot } from "./model";
import { useFolderTrustAsk } from "./useFolderTrustAsk";

// The pane's folder trust (App.tsx): which client and selection a rendered snapshot belongs to, the
// folder's question (useFolderTrustAsk.ts), and acpmux's trust refusals routed to the chat they came
// from. Kept out of App, which the React Compiler does not compile.

/// The client, selection generation and chat a rendered snapshot belongs to.
export type TrustRenderedOwner = { client?: AcpmuxDirectClient; generation?: number; sessionId?: string };

/// Who the shown snapshot belongs to, for the folder's question: its trust authority (connection and
/// host) and its visit (the client's selection identity then).
export function useTrustRoute(
  snapshot: AcpmuxSnapshot,
  catalogClientIdRef: RefObject<number>,
  directClientRef: RefObject<AcpmuxDirectClient | undefined>,
) {
  // Updated by the client before React renders, so a late Trust save cannot replay into a new
  // route during that interval. The catalog generation changes only when the client changes.
  const trustRouteSnapshot = useRef(snapshot);
  // The snapshot's owner is captured when the client publishes that snapshot. During a selection
  // hold the direct client may already point at B while the pane still paints A; never label that
  // rendered A with B's generation or let its Trust action target B.
  const trustRenderedOwner = useRef<TrustRenderedOwner | undefined>(undefined);
  const trustAuthority = useCallback(() => {
    const current = trustRouteSnapshot.current;
    return JSON.stringify([
      catalogClientIdRef.current,
      current.origin,
      current.answersTrust,
      directClientRef.current?.trustPeer ?? current.summary?.peer,
      current.summary?.hostKind,
      current.summary?.host,
    ]);
  }, [catalogClientIdRef, directClientRef]);
  const trustVisit = useCallback(() => {
    const client = directClientRef.current;
    const rendered = trustRenderedOwner.current;
    // A held snapshot is actionable only while its owner is still the client's live selection.
    // Return a fresh sentinel for a stale render so useFolderTrustAsk's sameVisit fence rejects
    // Trust/save/refusal callbacks even when React has not painted the replacement snapshot yet.
    // Native/gallery preview frames intentionally have no direct client; retain the unbound
    // visit semantics there so their host-backed Trust card remains interactive.
    if (!client) return undefined;
    if (
      !rendered ||
      rendered.client !== client ||
      rendered.generation !== client.trustGeneration ||
      rendered.sessionId !== client.selectedSession
    )
      return Symbol("stale-trust-visit");
    return JSON.stringify([rendered.generation, rendered.sessionId]);
  }, [directClientRef]);
  return { trustRouteSnapshot, trustRenderedOwner, trustAuthority, trustVisit };
}

/// A trust refusal that came while its chat was not the one routed: it is routed once that chat is.
type PendingTrustRefusal = {
  client: AcpmuxDirectClient;
  generation: number;
  sessionId?: string;
  cancelEpoch: number;
  error: unknown;
  again?: () => void;
  declined?: () => void;
};

/// The folder's trust question for the shown chat and the refs the connection's handlers read.
export function useChatTrust({
  source,
  snapshot,
  projectDraft,
  prompts,
  reread,
  local,
  blockSend,
  directClientRef,
  route,
}: {
  source: TrustSource;
  snapshot: AcpmuxSnapshot;
  projectDraft: string | undefined;
  prompts: number;
  reread: number;
  /// The chat's folder is on this computer (useFolderTrustAsk's `local`).
  local: boolean;
  blockSend: boolean;
  directClientRef: RefObject<AcpmuxDirectClient | undefined>;
  route: ReturnType<typeof useTrustRoute>;
}) {
  const { trustRenderedOwner, trustAuthority, trustVisit } = route;
  /// Takes acpmux's trust refusal of a prompt (useFolderTrustAsk.ts): the question shows for the
  /// folder it named, and `again` sends the held prompt after Trust.
  const peerTrustStarted = useRef<(() => void) | undefined>(undefined);
  const trustRefused = useRef<((error: unknown, again?: () => void, declined?: () => void) => boolean) | undefined>(
    undefined,
  );
  const trustCancelEpoch = useRef(0);
  const pendingTrustRefusal = useRef<PendingTrustRefusal | undefined>(undefined);
  const trustRouteOwner = useRef<
    { client: AcpmuxDirectClient; generation: number; sessionId?: string; cancelEpoch: number } | undefined
  >(undefined);
  // A folder without a trust answer is asked about beside the chat's other permission asks as
  // soon as the chat's folder is known (a new chat's chosen one before its first prompt). No
  // prompt goes until the answer is Trust; acpmux refuses one that does (`trust_gate.rs`).
  const answersTrust = snapshot.origin !== "remote" || snapshot.answersTrust === true;
  const trustAsk = useFolderTrustAsk(
    source,
    {
      sessionId: snapshot.sessionId,
      cwd: snapshot.summary?.cwd ?? (snapshot.sessionId ? undefined : projectDraft),
      family: snapshot.summary?.family || snapshot.summary?.harness,
      prompts,
      authority: trustAuthority,
      visit: trustVisit,
      reread,
    },
    answersTrust,
    local,
    blockSend,
  );
  // A no-folder recovery must not win over a trust answer made while its session switch is in
  // flight. The revision is advanced by Trust/Undo and by trust refusals, and read through a ref
  // because the host action handler outlives the render that installed it.
  const trustRevision = useRef(trustAsk.revision);
  const trustRoute = trustAsk.refused;
  // The connection's action table outlives renders; Retry must read the current folder/auth gate.
  const retryAfterTrust = useRef(trustAsk.retry);
  // The cards' context changes only when what they show does: Trust is a new function each render.
  const trustNow = useRef(trustAsk.trust);
  const sessionId = snapshot.sessionId;
  // The latest of each, written as the render commits: every reader is a handler or an effect.
  useInsertionEffect(() => {
    trustRevision.current = trustAsk.revision;
    trustRefused.current = trustRoute;
    peerTrustStarted.current = trustAsk.started;
    retryAfterTrust.current = trustAsk.retry;
    trustNow.current = trustAsk.trust;
    const rendered = trustRenderedOwner.current;
    const routeClient = rendered?.client;
    trustRouteOwner.current = routeClient
      ? {
          client: routeClient,
          generation: rendered?.generation ?? routeClient.trustGeneration,
          sessionId: rendered?.sessionId ?? sessionId,
          cancelEpoch: trustCancelEpoch.current,
        }
      : undefined;
  });
  const cancelTrustResend = useCallback(() => {
    const client = directClientRef.current;
    client?.cancelTrustRefusals();
    trustCancelEpoch.current += 1;
    pendingTrustRefusal.current = undefined;
    trustAsk.cancelResend();
  }, [trustAsk, directClientRef]);
  useEffect(() => {
    const pending = pendingTrustRefusal.current;
    const client = directClientRef.current;
    const owner = trustRouteOwner.current;
    if (
      !pending ||
      !client ||
      pending.client !== client ||
      pending.generation !== client.trustGeneration ||
      pending.cancelEpoch !== trustCancelEpoch.current ||
      !owner ||
      owner.client !== client ||
      owner.generation !== pending.generation ||
      (pending.sessionId !== undefined && client.shownSession()?.sessionId !== pending.sessionId)
    )
      return;
    if (trustRoute(pending.error, pending.again, pending.declined)) pendingTrustRefusal.current = undefined;
  }, [trustRoute, directClientRef]);
  return {
    answersTrust,
    trustAsk,
    peerTrustStarted,
    trustRefused,
    trustCancelEpoch,
    pendingTrustRefusal,
    trustRouteOwner,
    trustRevision,
    retryAfterTrust,
    trustNow,
    cancelTrustResend,
  };
}
