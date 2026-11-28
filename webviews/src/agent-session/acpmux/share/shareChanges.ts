// The host's `shareChanged {session}` (AgentPaneShareChanges.swift): the daemon says a chat's shares
// changed (an access request, a role change, a removal, a join), made anywhere. An open Share dialog
// listens for its own chat and reads the shares again, so it shows a request that comes in while
// it is open (Google Docs' Share dialog does).

type Listener = () => void;
const listeners = new Map<string, Set<Listener>>();

/** The host's push: each listener on `session` hears it. Anything but a session string does nothing. */
export function shareChanged(session: unknown): void {
  if (typeof session !== "string" || session.length === 0) return;
  for (const listener of [...(listeners.get(session) ?? [])]) listener();
}

/** Calls `listener` on each change of `session`'s shares; answers what stops it. */
export function onShareChanged(session: string, listener: Listener): () => void {
  let set = listeners.get(session);
  if (!set) listeners.set(session, (set = new Set()));
  set.add(listener);
  return () => {
    set.delete(listener);
    if (set.size === 0 && listeners.get(session) === set) listeners.delete(session);
  };
}
