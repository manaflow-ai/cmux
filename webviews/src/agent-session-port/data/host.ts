// The Swift host bridge (CmuxNextAgentPane, AgentPaneRequest): the same contract as the
// current pane, so the host serves either page unchanged. `ready` returns the acpmux
// endpoint and token; native-only actions (open in editor, dictation) also go through here.
type Reply<T> = { ok: true; value: T } | { ok: false; error?: { userMessage?: string } };

export type HostHandshake = {
  protocolVersion: number;
  transport?: string;
  endpoint?: string;
  token?: string;
  sessionId?: string;
  newSession?: boolean;
  cwd?: string;
  draft?: string;
  account?: unknown;
};

/** Calls a pane action: one the page registered itself (window.cmuxAcpmuxActions), else Swift. */
export function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler) return Promise.reject(new Error("Native bridge is unavailable"));
  return Promise.resolve(handler.postMessage({ id: crypto.randomUUID(), method, params }) as unknown as Reply<T>).then(
    (reply) => {
      if (!reply.ok) throw new Error(reply.error?.userMessage ?? "Request failed");
      return reply.value;
    },
  );
}
