/// A refusal has already passed the client's request-time cancellation/navigation fences.
/// Its UI route can lag behind that client during React's render gap: keep it until the
/// matching route is rendered rather than giving it to the old chat or dropping it.
export type TrustRefusalOwner<Client> = {
  client: Client;
  generation: number;
  sessionId?: string;
  cancelEpoch: number;
};

export function routeCurrentTrustRefusal<Client>(
  current: TrustRefusalOwner<Client>,
  rendered: TrustRefusalOwner<Client> | undefined,
  deliver: () => boolean,
  defer: () => void,
): void {
  if (
    rendered?.client === current.client &&
    rendered.generation === current.generation &&
    rendered.cancelEpoch === current.cancelEpoch &&
    rendered.sessionId === current.sessionId &&
    deliver()
  )
    return;
  defer();
}

export type PendingTrustRefusal<Client> = TrustRefusalOwner<Client> & {
  error: unknown;
  again?: () => void;
  declined?: () => void;
};

function sameOwner<Client>(left: TrustRefusalOwner<Client>, right: TrustRefusalOwner<Client>): boolean {
  return (
    left.client === right.client &&
    left.generation === right.generation &&
    left.sessionId === right.sessionId &&
    left.cancelEpoch === right.cancelEpoch
  );
}

/// The fallback for a request whose promise rejected: direct-client cancellation alone does not
/// fence this path. An old request cannot regain intent by reaching a fresh React callback.
export function routeOwnedTrustRefusal<Client>(
  owner: TrustRefusalOwner<Client>,
  current: TrustRefusalOwner<Client>,
  rendered: TrustRefusalOwner<Client> | undefined,
  pending: { current: PendingTrustRefusal<Client> | undefined },
  error: unknown,
  again: (() => void) | undefined,
  deliver: () => boolean,
  declined?: () => void,
): boolean {
  if (!sameOwner(owner, current)) return false;
  const held = pending.current;
  const heldError = held?.error as { reason?: unknown; cwd?: unknown } | undefined;
  const refusal = error as { reason?: unknown; cwd?: unknown };
  if (held && sameOwner(held, owner) && heldError?.reason === refusal.reason && heldError?.cwd === refusal.cwd) {
    // Keep the send's replay when the direct client already queued this same refusal.
    held.again = again;
    held.declined = declined;
    return true;
  }
  if (rendered && sameOwner(rendered, owner)) return deliver();
  pending.current = { ...owner, error, again, declined };
  return true;
}
