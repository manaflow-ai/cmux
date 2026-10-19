/// Grants belong to one attachment and card, rather than to reusable HTML source.
export const ranRenders = new Set<string>();
export const failedRenders = new Map<string, string>();
const attachments = new Map<string, number>();
const listeners = new Map<string, Set<() => void>>();

export const renderAttachment = (session: string) => attachments.get(session) ?? 0;

export function subscribeRenderAttachment(session: string, listener: () => void) {
  let callbacks = listeners.get(session);
  if (!callbacks) listeners.set(session, (callbacks = new Set()));
  callbacks.add(listener);
  return () => {
    callbacks.delete(listener);
    if (!callbacks.size) listeners.delete(session);
  };
}

export function renderExecutionKey(session: string, identity: unknown, attachment = renderAttachment(session)): string {
  return JSON.stringify([session, attachment, identity]);
}

export function resetRenderExecutions(session: string) {
  attachments.set(session, (attachments.get(session) ?? 0) + 1);
  for (const key of ranRenders) if (JSON.parse(key)[0] === session) ranRenders.delete(key);
  for (const key of failedRenders.keys()) if (JSON.parse(key)[0] === session) failedRenders.delete(key);
  for (const listener of listeners.get(session) ?? []) listener();
}
