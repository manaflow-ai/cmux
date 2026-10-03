// The page's requests to the native host: Swift's `agentSession` message handler
// (CmuxNextAgentPane AgentPaneRequest), which answers `{ok: true, value}` or `{ok: false, error}`.
import { NativeError, type NativeErrorReply } from "./nativeError";

type Reply<T> = { ok: true; value: T } | { ok: false; error?: NativeErrorReply };

/// Posts `method` to the native host. Rejects with a `NativeError` carrying the host's message and
/// error fields when it refuses, and when the page runs outside the app.
export function postNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler)
    return Promise.reject(
      new NativeError({ code: "native.not_connected", origin: "native" }, "Native bridge is unavailable"),
    );
  return Promise.resolve(handler.postMessage({ id: crypto.randomUUID(), method, params }) as unknown as Reply<T>).then(
    (reply) => {
      if (!reply.ok) throw new NativeError(reply.error);
      return reply.value;
    },
  );
}
