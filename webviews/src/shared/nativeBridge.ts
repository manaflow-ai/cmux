import { makeClientId } from "../agent-session/shared/ids";

/** The reply shape every native WebKit bridge returns from `postMessage`. */
export type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type NativeMessageHandler = {
  postMessage(message: unknown): Promise<NativeReply<unknown>>;
};

/** A native bridge instance: push-event subscription plus request/response. */
export type NativeBridge<Event> = {
  /** Registers a push-event listener; returns an unsubscribe function. */
  subscribe(listener: (event: Event) => void): () => void;
  /** Delivers a push event to every listener (wired to the `window` receiver). */
  receive(event: Event): void;
  /** Invokes a native bridge method, throwing on a `!ok` reply. */
  callNative<T>(method: string, params?: Record<string, unknown>): Promise<T>;
};

export type NativeBridgeConfig<Event> = {
  /** Key under `window.webkit.messageHandlers` (e.g. `"agentSession"`, `"kanban"`). */
  handlerName: string;
  /** Builds the error thrown on a failed reply — keeps each surface's own class. */
  makeError(message: string, code?: string): Error;
  /** Fallback message when a `!ok` reply carries no `userMessage`. */
  requestFailedMessage: string;
  /** Side effect run for every received event before fan-out (e.g. apply theme). */
  onReceive?(event: Event): void;
};

/**
 * Builds a native WebKit bridge for one webview surface. Centralizes the
 * request/response envelope, the listener fan-out, and the WebKit
 * `messageHandlers` lookup that the agent-session and Kanban bridges previously
 * copy-pasted, while keeping each surface's distinct error class, fallback copy,
 * and `window.cmux*Bridge` global where they belong.
 */
export function createNativeBridge<Event>(config: NativeBridgeConfig<Event>): NativeBridge<Event> {
  const listeners = new Set<(event: Event) => void>();

  function messageHandler(): NativeMessageHandler | null {
    if (typeof window === "undefined") {
      return null;
    }
    // The native bridge is injected at runtime by WebKit; narrow it through a
    // single boundary cast rather than declaring `window.webkit` globally, so
    // multiple surfaces can share this module without colliding on that type.
    const handlers = (
      window as unknown as {
        webkit?: { messageHandlers?: Record<string, NativeMessageHandler | undefined> };
      }
    ).webkit?.messageHandlers;
    const handler = handlers?.[config.handlerName];
    return handler && typeof handler.postMessage === "function" ? handler : null;
  }

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    receive(event) {
      config.onReceive?.(event);
      for (const listener of listeners) {
        listener(event);
      }
    },
    async callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
      const handler = messageHandler();
      if (!handler) {
        throw new Error("Native bridge is unavailable.");
      }
      const reply = (await handler.postMessage({
        id: makeClientId(),
        method,
        params,
      })) as NativeReply<T>;
      if (!reply.ok) {
        throw config.makeError(reply.error?.userMessage || config.requestFailedMessage, reply.error?.code);
      }
      return reply.value;
    },
  };
}
