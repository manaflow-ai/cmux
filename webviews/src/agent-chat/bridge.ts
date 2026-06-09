// WebKit bridge client for the /agent-chat surface.
//
// Mirrors the agent-session bridge pattern (`agent-session/shared/bridge.ts`):
// JS -> Swift requests go through `window.webkit.messageHandlers.agentChat`
// with the `{id, method, params}` envelope, Swift -> JS frames arrive through
// `window.cmuxAgentChatBridge.receive(message)`. When the WebKit handler is
// absent (vite dev, bun tests) the resolver falls back to a mock bridge that
// replays a built-in fixture stream, so the surface is fully developable
// standalone.

import { applyAgentTheme } from "../agent-session/shared/theme";
import { makeClientId } from "../agent-session/shared/ids";
import type { AgentSessionTheme } from "../agent-session/shared/types";
import type { AgentChatBridgeInbound, AgentChatInitResult } from "./protocol";
import { createMockAgentChatBridge } from "./mockBridge";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type AgentChatMessageHandler = {
  postMessage(message: unknown): Promise<NativeReply<unknown>>;
};

export type AgentChatInboundListener = (message: AgentChatBridgeInbound) => void;

/** Transport-agnostic client used by the surface; native or mock. */
export interface AgentChatBridgeClient {
  readonly kind: "mock" | "native";
  /** `chat.init` -> session + daemon status the panel was opened with. */
  init(): Promise<AgentChatInitResult>;
  /** `chat.subscribe` -> start the inbound `agent.event` stream. */
  subscribe(): Promise<void>;
  /** Stop any client-owned resources (mock replay timer). */
  dispose(): void;
}

declare global {
  interface Window {
    cmuxAgentChatBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      receive(message: AgentChatBridgeInbound): void;
    };
  }
}

export class AgentChatBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "AgentChatBridgeError";
    this.code = code;
  }
}

const listeners = new Set<AgentChatInboundListener>();

/**
 * Installs `window.cmuxAgentChatBridge` (the Swift -> JS entry point) on the
 * current window. Idempotent; safe to call from non-window contexts. The host
 * applies terminal theme tokens through `applyTheme` exactly like it does for
 * the agent-session surface (`window.cmuxAgentBridge.applyTheme`).
 */
export function ensureAgentChatBridgeInstalled(): void {
  if (typeof window === "undefined" || window.cmuxAgentChatBridge) {
    return;
  }
  window.cmuxAgentChatBridge = {
    applyTheme(theme: AgentSessionTheme) {
      applyAgentTheme(theme);
    },
    receive(message: AgentChatBridgeInbound) {
      // Set iteration tolerates listeners unsubscribing themselves mid-dispatch.
      for (const listener of listeners) {
        listener(message);
      }
    },
  };
}

ensureAgentChatBridgeInstalled();

export function subscribeToAgentChatInbound(listener: AgentChatInboundListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function nativeAgentChatHandler(): AgentChatMessageHandler | null {
  if (typeof window === "undefined") {
    return null;
  }
  // The agent-session bridge already declares `Window.webkit` globally with
  // only its own handler; read ours through a local cast instead of a second,
  // conflicting global declaration.
  const handler = (window as {
    webkit?: { messageHandlers?: { agentChat?: AgentChatMessageHandler } };
  }).webkit?.messageHandlers?.agentChat;
  return handler && typeof handler.postMessage === "function" ? handler : null;
}

async function callNative<T>(
  handler: AgentChatMessageHandler,
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;
  if (!reply.ok) {
    throw new AgentChatBridgeError(
      reply.error?.userMessage || "Native bridge request failed.",
      reply.error?.code,
    );
  }
  return reply.value;
}

/**
 * Picks the transport for this page: the WebKit message handler when the
 * macOS host injected one, otherwise the fixture-replaying mock bridge.
 */
export function resolveAgentChatBridge(): AgentChatBridgeClient {
  ensureAgentChatBridgeInstalled();
  const handler = nativeAgentChatHandler();
  if (handler) {
    return {
      kind: "native",
      init: () => callNative<AgentChatInitResult>(handler, "chat.init"),
      subscribe: () => callNative<void>(handler, "chat.subscribe"),
      dispose() {},
    };
  }
  return createMockAgentChatBridge();
}
