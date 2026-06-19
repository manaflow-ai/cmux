import type { AgentSessionTheme } from "../../agent-session/shared/types";
import { makeClientId } from "../../agent-session/shared/ids";
import { applyAgentTheme } from "../../agent-session/shared/theme";
import type { KanbanBoard } from "./types";

/** Push events the native coordinator sends to the board webview. */
export type KanbanEvent =
  | { type: "app.theme"; theme: AgentSessionTheme }
  | { type: "kanban.boardUpdated"; board: KanbanBoard };

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type EventListener = (event: KanbanEvent) => void;

/**
 * Native message-handler shape. Declared locally (not via a `Window`
 * augmentation) so it does not collide with the agent-session bridge's own
 * `window.webkit` declaration — both surfaces compile in the same project.
 */
type KanbanMessageHandler = {
  postMessage(message: unknown): Promise<NativeReply<unknown>>;
};

declare global {
  interface Window {
    cmuxKanbanBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      receive(event: KanbanEvent): void;
    };
  }
}

const listeners = new Set<EventListener>();

/** Error carrying the native `code` so the UI can branch on failure kinds. */
export class KanbanBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "KanbanBridgeError";
    this.code = code;
  }
}

if (typeof window !== "undefined") {
  window.cmuxKanbanBridge = {
    applyTheme(theme: AgentSessionTheme) {
      applyAgentTheme(theme);
    },
    receive(event: KanbanEvent) {
      if (event.type === "app.theme") {
        applyAgentTheme(event.theme);
      }
      for (const listener of listeners) {
        listener(event);
      }
    },
  };
}

export function subscribeToKanbanEvents(listener: EventListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function kanbanMessageHandler(): KanbanMessageHandler | null {
  if (typeof window === "undefined") {
    return null;
  }
  // The native bridge is injected at runtime by WebKit; narrow it through a
  // single boundary cast rather than polluting the global `Window` type.
  const messageHandlers = (
    window as unknown as {
      webkit?: { messageHandlers?: { kanban?: KanbanMessageHandler } };
    }
  ).webkit?.messageHandlers;
  const handler = messageHandlers?.kanban;
  return handler && typeof handler.postMessage === "function" ? handler : null;
}

export async function callNativeKanban<T>(
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  const handler = kanbanMessageHandler();
  if (!handler) {
    throw new Error("Native bridge is unavailable.");
  }

  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;

  if (!reply.ok) {
    throw new KanbanBridgeError(reply.error?.userMessage || "Board request failed.", reply.error?.code);
  }

  return reply.value;
}
