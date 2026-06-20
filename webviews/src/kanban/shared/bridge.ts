import type { AgentSessionTheme } from "../../agent-session/shared/types";
import { applyAgentTheme } from "../../agent-session/shared/theme";
import { createNativeBridge } from "../../shared/nativeBridge";
import type { KanbanBoard } from "./types";

/**
 * A per-card dispatch lifecycle event. The board column updates via
 * `kanban.boardUpdated`; this carries the fine-grained run progress (live agent
 * output, session id, worktree, exit) so the UI can show a status line.
 */
export type KanbanTaskProgress =
  | { type: "kanban.taskProgress"; cardId: string; kind: "started"; sessionId: string }
  | {
      type: "kanban.taskProgress";
      cardId: string;
      kind: "provisioned";
      worktreePath: string;
      branchName: string;
    }
  | { type: "kanban.taskProgress"; cardId: string; kind: "output"; text: string }
  | { type: "kanban.taskProgress"; cardId: string; kind: "turnComplete" }
  | { type: "kanban.taskProgress"; cardId: string; kind: "exited"; status: number }
  | { type: "kanban.taskProgress"; cardId: string; kind: "failed"; message: string };

/** Push events the native coordinator sends to the board webview. */
export type KanbanEvent =
  | { type: "app.theme"; theme: AgentSessionTheme }
  | { type: "kanban.boardUpdated"; board: KanbanBoard }
  | KanbanTaskProgress;

/** Error carrying the native `code` so the UI can branch on failure kinds. */
export class KanbanBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "KanbanBridgeError";
    this.code = code;
  }
}

declare global {
  interface Window {
    cmuxKanbanBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      receive(event: KanbanEvent): void;
    };
  }
}

const bridge = createNativeBridge<KanbanEvent>({
  handlerName: "kanban",
  makeError: (message, code) => new KanbanBridgeError(message, code),
  requestFailedMessage: "Board request failed.",
  onReceive: (event) => {
    if (event.type === "app.theme") {
      applyAgentTheme(event.theme);
    }
  },
});

if (typeof window !== "undefined") {
  window.cmuxKanbanBridge = {
    applyTheme(theme: AgentSessionTheme) {
      applyAgentTheme(theme);
    },
    receive: bridge.receive,
  };
}

export function subscribeToKanbanEvents(listener: (event: KanbanEvent) => void): () => void {
  return bridge.subscribe(listener);
}

export function callNativeKanban<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  return bridge.callNative<T>(method, params);
}
