import { createPageClient, type PageClient } from "../pages/shared/pageClient";

export type ActivityNative = {
  request<T>(method: string, params?: Record<string, unknown>): Promise<T>;
  onState(callback: (state: unknown) => void): void;
};

/** The page host's op and stream names (CmuxNextApp AgentActivityPageProvider). */
export const ACTIVITY_OP_PREFIX = "cmux.agentActivity.";
export const ACTIVITY_STATE_STREAM = "cmux.agentActivity.state";

/**
 * The Activity page on the shared page host (`cmux-page://cmux.agent-activity`, WebKit or
 * Chromium): each request is a page op, and state changes arrive on one stream.
 */
export function pageHostNative(client: PageClient): ActivityNative {
  return {
    request(method, params = {}) {
      return client.call(ACTIVITY_OP_PREFIX + method, params);
    },
    onState(callback) {
      void client.subscribe(ACTIVITY_STATE_STREAM, (state) => callback(state));
    },
  };
}

/** The old WebKit-only host (`AgentActivityHostView`): a reply handler and a pushed callback. */
const webKitNative: ActivityNative = {
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

const client = createPageClient();
export const native: ActivityNative = client ? pageHostNative(client) : webKitNative;
