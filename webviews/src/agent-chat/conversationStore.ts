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
  /**
   * Item id -> index into `items`, kept in lockstep so `item.*` upserts avoid
   * a full rescan per streamed event. Rebuilt on snapshot.
   */
  itemIndexById: ReadonlyMap<string, number>;
  daemonStatus: DaemonStatus;
  daemonDetail: string | null;
  /**
   * `chat.subscribe` failure detail after a successful init. Distinct from
   * `daemonStatus`: the daemon may be perfectly reachable while this
   * session's stream could not be opened (e.g. transcript missing).
   */
  subscribeError: string | null;
  /** Events whose `type` this build does not know (logged, never crashed on). */
  unknownEventCount: number;
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
  | { type: "subscribe-failed"; detail: string }
  | { type: "inbound"; message: AgentChatBridgeInbound };

export function initialConversationState(): ConversationState {
  return {
    phase: "connecting",
    session: null,
    items: [],
    itemIndexById: new Map(),
    daemonStatus: "ready",
    daemonDetail: null,
    subscribeError: null,
    unknownEventCount: 0,
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
    case "subscribe-failed":
      // Init succeeded (the daemon answered), so this is a per-session
      // stream failure, not daemon unavailability; keep daemonStatus as
      // reported by init.
      return {
        ...state,
        phase: "failed",
        subscribeError: action.detail,
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
      itemIndexById: buildItemIndex(event.items),
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
    case "item.completed": {
      const upserted = upsertItem(state.items, state.itemIndexById, event.item);
      return {
        ...state,
        lastSeq: event.seq,
        items: upserted.items,
        itemIndexById: upserted.itemIndexById,
      };
    }
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
    default: {
      // The protocol reserves names (e.g. content.delta) and newer daemons
      // may emit types this build does not know; count and skip them instead
      // of letting the reducer return undefined and break the surface.
      const unknown = event as { type?: unknown; seq: number };
      console.warn("agent-chat: ignoring unknown agent event type", unknown.type);
      return { ...state, lastSeq: unknown.seq, unknownEventCount: state.unknownEventCount + 1 };
    }
  }
}

function buildItemIndex(items: readonly ConversationItem[]): ReadonlyMap<string, number> {
  const index = new Map<string, number>();
  items.forEach((item, position) => {
    index.set(item.id, position);
  });
  return index;
}

function upsertItem(
  items: ConversationItem[],
  itemIndexById: ReadonlyMap<string, number>,
  item: ConversationItem,
): { items: ConversationItem[]; itemIndexById: ReadonlyMap<string, number> } {
  const index = itemIndexById.get(item.id);
  if (index === undefined) {
    const appended = new Map(itemIndexById);
    appended.set(item.id, items.length);
    return { items: [...items, item], itemIndexById: appended };
  }
  const next = items.slice();
  next[index] = item;
  // In-place replacement leaves every id at its index; reuse the map.
  return { items: next, itemIndexById };
}

/**
 * Whether the agent is visibly mid-work: a hook-observed turn is open, a tool
 * call is still in progress, or the newest renderable item is the user's
 * message awaiting a reply. Drives the typing indicator; purely derived.
 */
export function isAgentWorking(state: ConversationState): boolean {
  if (state.daemonStatus !== "ready" || !state.hasSnapshot) {
    return false;
  }
  if (state.activeTurn !== null) {
    return true;
  }
  if (state.items.some((item) => item.status === "in_progress")) {
    return true;
  }
  const last = state.items[state.items.length - 1];
  return last !== undefined && last.type === "user_message";
}
