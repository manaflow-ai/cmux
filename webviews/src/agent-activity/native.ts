export type ActivityNative = {
  request<T>(method: string, params?: Record<string, unknown>): Promise<T>;
  onState(callback: (state: unknown) => void): void;
};
export const native: ActivityNative = {
  request(method, params = {}) {
    const handler = (window as any).webkit?.messageHandlers?.agentActivity;
    if (!handler) return Promise.reject(new Error("Agent Activity bridge is unavailable"));
    return Promise.resolve(
      handler.postMessage({ id: crypto.randomUUID(), method, params }) as unknown as {
        ok: boolean;
        value?: unknown;
        error?: { userMessage?: string };
      },
    ).then((reply) => {
      if (!reply.ok) throw new Error(reply.error?.userMessage ?? "Agent Activity request failed");
      return reply.value as any;
    });
  },
  onState(callback) {
    (window as any).cmuxActivityReceive = callback;
  },
};
