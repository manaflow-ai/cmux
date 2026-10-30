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
