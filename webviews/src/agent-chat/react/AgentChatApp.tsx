// /agent-chat surface: read-only structured chat timeline over the normalized
// agent conversation protocol (see ../protocol.ts and
// docs/agent-conversation-protocol.md).

import { useEffect, useReducer, useState } from "react";
import type { UIEvent as ReactUIEvent, ReactNode } from "react";
import {
  resolveAgentChatBridge,
  subscribeToAgentChatInbound,
  type AgentChatBridgeClient,
} from "../bridge";
import {
  initialConversationState,
  reduceConversation,
  type ConversationAction,
  type ConversationState,
} from "../conversationStore";
import { providerDisplayName, sessionDisplayTitle } from "./display";
import { ItemRow, TurnSeparator } from "./rows";

/** Distance from the bottom (px) still treated as "at the bottom". */
const FOLLOW_THRESHOLD_PX = 24;

type BridgeFactory = () => AgentChatBridgeClient;

/**
 * Connects the panel to the agent-chat bridge for the lifetime of the
 * component: registers the inbound listener, performs `chat.init`, then
 * `chat.subscribe`. Narrow contract: runs once per (stable) factory, forwards
 * everything as reducer actions, and disposes the bridge client on unmount.
 * This is the surface's one lifecycle effect, mirroring the agent-session
 * surface's `useInitialData`/`useNativeEvents` hooks.
 */
function useAgentChatConnection(
  dispatch: (action: ConversationAction) => void,
  createBridge: BridgeFactory | undefined,
) {
  useEffect(() => {
    const bridge = createBridge ? createBridge() : resolveAgentChatBridge();
    const unsubscribe = subscribeToAgentChatInbound((message) => {
      dispatch({ type: "inbound", message });
    });
    let cancelled = false;
    void (async () => {
      try {
        const result = await bridge.init();
        if (cancelled) {
          return;
        }
        dispatch({ type: "init", result });
        await bridge.subscribe();
      } catch (error) {
        if (!cancelled) {
          dispatch({
            type: "init-failed",
            detail: error instanceof Error ? error.message : "Agent bridge request failed.",
          });
        }
      }
    })();
    return () => {
      cancelled = true;
      unsubscribe();
      bridge.dispose();
    };
  }, [dispatch, createBridge]);
}

export function AgentChatApp({ createBridge }: { createBridge?: BridgeFactory }) {
  const [state, dispatch] = useReducer(
    reduceConversation,
    undefined,
    initialConversationState,
  );
  useAgentChatConnection(dispatch, createBridge);
  return (
    <div className="agent-chat-shell">
      <HeaderStrip state={state} />
      {state.daemonStatus === "unavailable" && state.items.length > 0 ? (
        <DaemonBanner detail={state.daemonDetail} />
      ) : null}
      <TimelineBody state={state} />
    </div>
  );
}

function HeaderStrip({ state }: { state: ConversationState }) {
  const session = state.session;
  return (
    <header className="agent-chat-header">
      <span className="agent-chat-provider-badge" data-provider={session?.provider ?? ""}>
        {providerDisplayName(session?.provider)}
      </span>
      <span className="agent-chat-header-titles">
        <span className="agent-chat-header-title">{sessionDisplayTitle(session)}</span>
        {session?.cwd ? <span className="agent-chat-header-cwd">{session.cwd}</span> : null}
      </span>
      <span
        className={`agent-chat-daemon-status is-${state.daemonStatus}`}
        title={state.daemonStatus === "unavailable" ? (state.daemonDetail ?? undefined) : undefined}
      >
        <span className="agent-chat-daemon-dot" aria-hidden="true" />
        {state.daemonStatus === "unavailable" ? "Daemon unavailable" : "Live"}
      </span>
    </header>
  );
}

function DaemonBanner({ detail }: { detail: string | null }) {
  return (
    <output className="agent-chat-daemon-banner">
      Agent daemon unavailable{detail ? `: ${detail}` : "."} Showing the last known transcript.
    </output>
  );
}

function TimelineBody({ state }: { state: ConversationState }) {
  if (state.phase === "connecting") {
    return <EmptyState title="Connecting" detail="Reaching the agent daemon…" />;
  }
  if (state.daemonStatus === "unavailable" && state.items.length === 0) {
    return (
      <EmptyState
        title="Agent daemon unavailable"
        detail={state.daemonDetail ?? "The conversation daemon could not be reached."}
      />
    );
  }
  if (!state.hasSnapshot && state.session === null) {
    return (
      <EmptyState
        title="No session"
        detail="No agent session was resolved for this pane."
      />
    );
  }
  if (!state.hasSnapshot) {
    return <EmptyState title="Loading transcript" detail="Waiting for the first snapshot…" />;
  }
  if (state.items.length === 0) {
    return (
      <EmptyState
        title="No conversation yet"
        detail="This session's transcript has no items so far."
      />
    );
  }
  return <Timeline state={state} />;
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return (
    <div className="agent-chat-empty" data-empty-title={title}>
      <span className="agent-chat-empty-title">{title}</span>
      <span className="agent-chat-empty-detail">{detail}</span>
    </div>
  );
}

function Timeline({ state }: { state: ConversationState }) {
  // Auto-follow is fully derived: `unfollowedAtSeq === null` means "stick to
  // the bottom". Scroll events flip it (leaving the bottom unfollows, reaching
  // the bottom re-follows), and the seq recorded at unfollow time tells us
  // whether new items arrived for the jump-to-latest pill. No effects: the
  // bottom anchor below is keyed by lastSeq, so every applied event remounts
  // it and its callback ref re-pins the viewport while following.
  const [scrollContainer, setScrollContainer] = useState<HTMLDivElement | null>(null);
  const [unfollowedAtSeq, setUnfollowedAtSeq] = useState<number | null>(null);
  const following = unfollowedAtSeq === null;
  const hasNewWhileUnfollowed = unfollowedAtSeq !== null && state.lastSeq > unfollowedAtSeq;

  const scrollToBottom = (node: HTMLElement | null) => {
    if (node) {
      // Instant (non-smooth) jump: the resulting scroll event lands at the
      // bottom in one step, so the handler below keeps `following` stable.
      node.scrollTop = node.scrollHeight;
    }
  };

  const handleScroll = (event: ReactUIEvent<HTMLDivElement>) => {
    const node = event.currentTarget;
    const atBottom =
      node.scrollTop + node.clientHeight >= node.scrollHeight - FOLLOW_THRESHOLD_PX;
    if (atBottom) {
      if (unfollowedAtSeq !== null) {
        setUnfollowedAtSeq(null);
      }
    } else if (unfollowedAtSeq === null) {
      setUnfollowedAtSeq(state.lastSeq);
    }
  };

  const anchorRef = (node: HTMLDivElement | null) => {
    if (node && following) {
      scrollToBottom(node.parentElement);
    }
  };

  const rows: ReactNode[] = [];
  state.items.forEach((item, index) => {
    if (item.type === "user_message" && index > 0) {
      rows.push(<TurnSeparator key={`turn-${item.id}`} />);
    }
    rows.push(<ItemRow key={item.id} item={item} />);
  });

  return (
    <div className="agent-chat-timeline">
      <div
        className="agent-chat-scroll"
        ref={setScrollContainer}
        onScroll={handleScroll}
        data-following={following ? "true" : "false"}
      >
        {rows}
        {state.streamError ? (
          <div className="agent-chat-row agent-chat-system-row is-error" data-stream-error="true">
            <span className="agent-chat-system-label">Stream error</span>
            <span className="agent-chat-system-text">
              {state.streamError.message}
              {state.streamError.recoverable ? " (retrying)" : ""}
            </span>
          </div>
        ) : null}
        <div key={`anchor-${state.lastSeq}`} ref={anchorRef} className="agent-chat-anchor" />
      </div>
      {!following && hasNewWhileUnfollowed ? (
        <button
          type="button"
          className="agent-chat-jump-latest"
          onClick={() => {
            scrollToBottom(scrollContainer);
            setUnfollowedAtSeq(null);
          }}
        >
          ↓ Jump to latest
        </button>
      ) : null}
    </div>
  );
}
