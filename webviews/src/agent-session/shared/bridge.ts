import type { AgentEvent, AgentSessionTheme } from "./types";
import { makeClientId } from "./ids";
import { applyAgentTheme } from "./theme";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type EventListener = (event: AgentEvent) => void;
type ComposerPointerDownHandler = (x: number, y: number) => boolean;

declare global {
  interface Window {
    cmuxAgentBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      focusComposer(): void;
      pointerDownAt(x: number, y: number): boolean;
      receive(event: AgentEvent): void;
      submitComposer(): boolean;
    };
    webkit?: {
      messageHandlers?: {
        agentSession?: {
          postMessage(message: unknown): Promise<NativeReply<unknown>>;
        };
      };
    };
  }
}

const listeners = new Set<EventListener>();
let composerFocusHandler: (() => void) | undefined;
let composerPointerDownHandler: ComposerPointerDownHandler | undefined;
let composerSubmitHandler: (() => boolean) | undefined;

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
    focusComposer() {
      composerFocusHandler?.();
    },
    pointerDownAt(x: number, y: number) {
      return composerPointerDownHandler?.(x, y) ?? false;
    },
    receive(event: AgentEvent) {
      if (event.type === "app.theme") {
        applyAgentTheme(event.theme);
      }
      for (const listener of listeners) {
        listener(event);
      }
    },
    submitComposer() {
      return composerSubmitHandler?.() ?? false;
    },
  };
}

export function setComposerFocusHandler(handler: () => void): () => void {
  composerFocusHandler = handler;
  return () => {
    if (composerFocusHandler === handler) {
      composerFocusHandler = undefined;
    }
  };
}

export function setComposerPointerDownHandler(handler: ComposerPointerDownHandler): () => void {
  composerPointerDownHandler = handler;
  return () => {
    if (composerPointerDownHandler === handler) {
      composerPointerDownHandler = undefined;
    }
  };
}

export function setComposerSubmitHandler(handler: () => boolean): () => void {
  composerSubmitHandler = handler;
  return () => {
    if (composerSubmitHandler === handler) {
      composerSubmitHandler = undefined;
    }
  };
}

export function subscribeToAgentEvents(listener: EventListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
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
