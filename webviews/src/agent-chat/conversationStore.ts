// Pure conversation state for the /agent-chat surface.
//
// `reduceConversation` is the single state transition for the panel: the init
// reply, daemon status frames, and the `AgentEvent` stream all flow through
// it. `applyAgentEvent` implements the protocol's ordering rules: a snapshot
// replaces the item list and resets the sequence cursor, `item.*` events
// upsert by item id while preserving first-appearance order, and stale events
// (`seq` at or below the cursor) are ignored except for fresh snapshots.
// Hook-sourced events maintain `pendingRequests` (request.opened minus
// request.resolved), `activeTurn`, and `turnStarts` (real turn boundaries by
// item index); all three reset on snapshot.

import type {
  AgentChatBridgeInbound,
  AgentChatInitResult,
  AgentEvent,
  AgentSessionRef,
  ConversationItem,
  RequestType,
} from "./protocol";

export type DaemonStatus = "ready" | "unavailable";

export type ConversationPhase = "connecting" | "failed" | "ready";

/** A `request.opened` not yet matched by its `request.resolved`. */
export type PendingRequest = {
  id: string;
  request_type: RequestType;
  detail?: string;
};

/** The live turn opened by `turn.started` and not yet completed. */
export type ActiveTurn = {
  id: string;
  prompt?: string;
};

export type ConversationState = {
  /** Bridge lifecycle: init pending, init replied, or init threw. */
  phase: ConversationPhase;
  session: AgentSessionRef | null;
  /** Ordered by first appearance; updates replace in place. */
  items: ConversationItem[];
  daemonStatus: DaemonStatus;
  daemonDetail: string | null;
  /** Highest applied event seq; 0 before the first snapshot. */
  lastSeq: number;
  /** True once a snapshot has been applied (distinguishes empty transcripts). */
  hasSnapshot: boolean;
  /** Last stream-level `error` event, cleared by the next snapshot. */
  streamError: { message: string; recoverable: boolean } | null;
  /** Open requests (opened minus resolved), in open order. */
  pendingRequests: PendingRequest[];
  /** Non-null while a hook-observed turn is running. */
  activeTurn: ActiveTurn | null;
  /**
   * Item indexes at which a real (hook-observed) turn started. Non-empty means
   * the timeline can draw real turn boundaries instead of deriving them from
   * user_message items.
   */
  turnStarts: number[];
};

export type ConversationAction =
  | { type: "init"; result: AgentChatInitResult }
  | { type: "init-failed"; detail: string }
  | { type: "inbound"; message: AgentChatBridgeInbound };

export function initialConversationState(): ConversationState {
  return {
    phase: "connecting",
    session: null,
    items: [],
    daemonStatus: "ready",
    daemonDetail: null,
    lastSeq: 0,
    hasSnapshot: false,
    streamError: null,
    pendingRequests: [],
    activeTurn: null,
    turnStarts: [],
  };
}

export function reduceConversation(
  state: ConversationState,
  action: ConversationAction,
): ConversationState {
  switch (action.type) {
    case "init":
      return {
        ...state,
        phase: "ready",
        session: action.result.session ?? state.session,
        daemonStatus: action.result.daemon_status,
        daemonDetail: action.result.daemon_detail ?? null,
      };
    case "init-failed":
      return {
        ...state,
        phase: "failed",
        daemonStatus: "unavailable",
        daemonDetail: action.detail,
      };
    case "inbound":
      if (action.message.type === "daemon.status") {
        return {
          ...state,
          daemonStatus: action.message.status,
          daemonDetail: action.message.detail ?? null,
        };
      }
      return applyAgentEvent(state, action.message.event);
  }
}

export function applyAgentEvent(state: ConversationState, event: AgentEvent): ConversationState {
  // A fresh snapshot always applies: it is the reconnect/replace point and
  // resets the sequence cursor (the daemon restarts seq per subscription).
  // Hook-derived state (requests, turns) is ephemeral and resets with it.
  if (event.type === "snapshot") {
    return {
      ...state,
      hasSnapshot: true,
      lastSeq: event.seq,
      session: event.session,
      items: [...event.items],
      streamError: null,
      pendingRequests: [],
      activeTurn: null,
      turnStarts: [],
    };
  }
  // Seq regression guard: drop stale or duplicate frames.
  if (event.seq <= state.lastSeq) {
    return state;
  }
  switch (event.type) {
    case "item.started":
    case "item.updated":
    case "item.completed":
      return { ...state, lastSeq: event.seq, items: upsertItem(state.items, event.item) };
    case "session.meta":
      return { ...state, lastSeq: event.seq, session: event.session };
    case "error":
      return {
        ...state,
        lastSeq: event.seq,
        streamError: { message: event.message, recoverable: event.recoverable },
      };
    case "turn.started": {
      // The boundary sits before the next item to arrive.
      const boundary = state.items.length;
      return {
        ...state,
        lastSeq: event.seq,
        activeTurn: { id: event.turn_id, prompt: event.prompt },
        turnStarts: state.turnStarts.includes(boundary)
          ? state.turnStarts
          : [...state.turnStarts, boundary],
      };
    }
    case "turn.completed":
      return { ...state, lastSeq: event.seq, activeTurn: null };
    case "request.opened": {
      if (state.pendingRequests.some((request) => request.id === event.request_id)) {
        return { ...state, lastSeq: event.seq };
      }
      return {
        ...state,
        lastSeq: event.seq,
        pendingRequests: [
          ...state.pendingRequests,
          { id: event.request_id, request_type: event.request_type, detail: event.detail },
        ],
      };
    }
    case "request.resolved":
      return {
        ...state,
        lastSeq: event.seq,
        pendingRequests: state.pendingRequests.filter(
          (request) => request.id !== event.request_id,
        ),
      };
  }
}

function upsertItem(items: ConversationItem[], item: ConversationItem): ConversationItem[] {
  const index = items.findIndex((existing) => existing.id === item.id);
  if (index < 0) {
    return [...items, item];
  }
  const next = items.slice();
  next[index] = item;
  return next;
}
