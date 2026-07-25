import type { AgentEvent, AgentSessionTheme } from "./types";
import { makeClientId } from "./ids";
import { applyAgentTheme } from "./theme";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type EventListener = (event: AgentEvent) => void;

declare global {
  interface Window {
    cmuxAgentBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      receive(event: AgentEvent): void;
    };
  }
}

const listeners = new Set<EventListener>();
const pendingEvents: AgentEvent[] = [];
const maxPendingEvents = 512;

export class NativeBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "NativeBridgeError";
    this.code = code;
  }
}

if (typeof window !== "undefined") {
  window.cmuxAgentBridge = {
    applyTheme(theme: AgentSessionTheme) {
      applyAgentTheme(theme);
    },
    receive: receiveAgentEvent,
  };
}

export function subscribeToAgentEvents(listener: EventListener): () => void {
  listeners.add(listener);
  if (pendingEvents.length > 0) {
    const replay = pendingEvents.splice(0);
    for (const event of replay) {
      listener(event);
    }
  }
  return () => {
    listeners.delete(listener);
  };
}

function receiveAgentEvent(event: AgentEvent): void {
  if (event.type === "app.theme") {
    applyAgentTheme(event.theme);
  }
  if (listeners.size === 0) {
    pendingEvents.push(event);
    if (pendingEvents.length > maxPendingEvents) {
      pendingEvents.splice(0, pendingEvents.length - maxPendingEvents);
    }
    return;
  }
  for (const listener of listeners) {
    listener(event);
  }
}

export function __receiveAgentEventForTests(event: AgentEvent): void {
  receiveAgentEvent(event);
}

export function __resetAgentBridgeForTests(): void {
  listeners.clear();
  pendingEvents.splice(0);
}

export async function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (typeof window === "undefined") {
    throw new Error("Native bridge is unavailable.");
  }
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler || typeof handler.postMessage !== "function") {
    throw new Error("Native bridge is unavailable.");
  }

  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;

  if (!reply.ok) {
    throw new NativeBridgeError(reply.error?.userMessage || "Native bridge request failed.", reply.error?.code);
  }

  return reply.value;
}
