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
  isAgentWorking,
  reduceConversation,
  type ConversationAction,
  type ConversationState,
} from "../conversationStore";
import { agentChatLabels } from "../labels";
import {
  clampCursor,
  computeMatches,
  initialSearchUIState,
  normalizeSearchQuery,
  reduceSearchUI,
} from "../search";
import { applyAgentChatTheme } from "../theme";
import { providerDisplayName, sessionDisplayTitle } from "./display";
import { ItemRow, PendingRequestBanner, TurnSeparator } from "./rows";
import { SearchBar, useSearchHotkey } from "./SearchBar";

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
      let result;
      try {
        result = await bridge.init();
      } catch (error) {
        if (!cancelled) {
          dispatch({
            type: "init-failed",
            detail: error instanceof Error ? error.message : agentChatLabels.bridgeRequestFailed,
          });
        }
        return;
      }
      if (cancelled) {
        return;
      }
      // Terminal theme tokens ride the init reply so the first paint is
      // already themed; later appearance changes arrive as
      // `cmuxAgentChatBridge.applyTheme` pushes (bridge.ts).
      applyAgentChatTheme(result.theme);
      dispatch({ type: "init", result });
      try {
        await bridge.subscribe();
      } catch (error) {
        // A failed subscribe after a successful init is a per-session stream
        // failure (e.g. missing transcript), not daemon unavailability.
        if (!cancelled) {
          dispatch({
            type: "subscribe-failed",
            detail: error instanceof Error ? error.message : agentChatLabels.bridgeRequestFailed,
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

  // Search is fully derived from (items, search UI state): the match list and
  // cursor are recomputed per render, never stored. An open bar with an empty
  // query leaves the timeline untouched.
  const [searchUI, dispatchSearch] = useReducer(reduceSearchUI, undefined, initialSearchUIState);
  const activeQuery = searchUI.open ? normalizeSearchQuery(searchUI.query) : "";
  const matches = computeMatches(state.items, activeQuery);
  const cursor = clampCursor(searchUI.cursor, matches.length);
  const currentMatchId = matches.length > 0 ? state.items[matches[cursor]].id : null;

  const openSearch = () => dispatchSearch({ type: "open" });
  useSearchHotkey(openSearch);
  const stepSearch = (direction: 1 | -1) => {
    if (matches.length === 0) {
      return;
    }
    // Compute the destination with the reducer's own arithmetic so the
    // imperative scroll targets exactly the row the next render marks current.
    const next = (cursor + direction + matches.length) % matches.length;
    dispatchSearch({ type: "step", direction, matchCount: matches.length });
    const target = state.items[matches[next]];
    document
      .querySelector(`[data-item-id="${CSS.escape(target.id)}"]`)
      ?.scrollIntoView({ block: "center" });
  };

  return (
    <div className="agent-chat-shell">
      <HeaderStrip state={state} onOpenSearch={openSearch} />
      {searchUI.open ? (
        <SearchBar
          openCount={searchUI.openCount}
          query={searchUI.query}
          filterMode={searchUI.filterMode}
          cursor={cursor}
          matchCount={matches.length}
          onQueryChange={(query) => dispatchSearch({ type: "set-query", query })}
          onStep={stepSearch}
          onToggleFilter={() => dispatchSearch({ type: "toggle-filter" })}
          onClose={() => dispatchSearch({ type: "close" })}
        />
      ) : null}
      {state.daemonStatus === "unavailable" && state.items.length > 0 ? (
        <DaemonBanner detail={state.daemonDetail} />
      ) : null}
      {state.pendingRequests.map((request) => (
        <PendingRequestBanner key={request.id} request={request} />
      ))}
      <TimelineBody
        state={state}
        searchQuery={activeQuery}
        matchedIndexes={matches}
        currentMatchId={currentMatchId}
        filterMode={searchUI.filterMode}
      />
    </div>
  );
}

function HeaderStrip({
  state,
  onOpenSearch,
}: {
  state: ConversationState;
  onOpenSearch: () => void;
}) {
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
      <button
        type="button"
        className="agent-chat-header-search"
        title={agentChatLabels.searchOpen}
        aria-label={agentChatLabels.searchOpen}
        onClick={onOpenSearch}
      >
        ⌕
      </button>
      <span
        className={`agent-chat-daemon-status is-${state.daemonStatus}`}
        title={state.daemonStatus === "unavailable" ? (state.daemonDetail ?? undefined) : undefined}
      >
        <span className="agent-chat-daemon-dot" aria-hidden="true" />
        {state.daemonStatus === "unavailable"
          ? agentChatLabels.statusDaemonUnavailable
          : agentChatLabels.statusLive}
      </span>
    </header>
  );
}

function DaemonBanner({ detail }: { detail: string | null }) {
  return (
    <output className="agent-chat-daemon-banner">
      {agentChatLabels.daemonBannerTitle}
      {detail ? `: ${detail}` : "."} {agentChatLabels.daemonBannerSuffix}
    </output>
  );
}

type SearchRenderProps = {
  /** Normalized active query; "" when search is closed or blank. */
  searchQuery: string;
  /** Indexes into state.items of the matching items, timeline order. */
  matchedIndexes: number[];
  currentMatchId: string | null;
  filterMode: boolean;
};

function TimelineBody({
  state,
  searchQuery,
  matchedIndexes,
  currentMatchId,
  filterMode,
}: { state: ConversationState } & SearchRenderProps) {
  if (state.phase === "connecting") {
    return (
      <EmptyState
        title={agentChatLabels.connectingTitle}
        detail={agentChatLabels.connectingDetail}
      />
    );
  }
  if (state.daemonStatus === "unavailable" && state.items.length === 0) {
    return (
      <EmptyState
        title={agentChatLabels.daemonUnavailableTitle}
        detail={state.daemonDetail ?? agentChatLabels.daemonUnavailableDetail}
      />
    );
  }
  if (state.subscribeError !== null && !state.hasSnapshot) {
    return (
      <EmptyState
        title={agentChatLabels.subscribeFailedTitle}
        detail={state.subscribeError || agentChatLabels.subscribeFailedDetail}
      />
    );
  }
  if (!state.hasSnapshot && state.session === null) {
    return (
      <EmptyState
        title={agentChatLabels.noSessionTitle}
        detail={agentChatLabels.noSessionDetail}
      />
    );
  }
  if (!state.hasSnapshot) {
    return (
      <EmptyState title={agentChatLabels.loadingTitle} detail={agentChatLabels.loadingDetail} />
    );
  }
  if (state.items.length === 0) {
    return (
      <EmptyState
        title={agentChatLabels.noConversationTitle}
        detail={agentChatLabels.noConversationDetail}
      />
    );
  }
  return (
    <Timeline
      state={state}
      searchQuery={searchQuery}
      matchedIndexes={matchedIndexes}
      currentMatchId={currentMatchId}
      filterMode={filterMode}
    />
  );
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return (
    <div className="agent-chat-empty" data-empty-title={title}>
      <span className="agent-chat-empty-title">{title}</span>
      <span className="agent-chat-empty-detail">{detail}</span>
    </div>
  );
}

function Timeline({
  state,
  searchQuery,
  matchedIndexes,
  currentMatchId,
  filterMode,
}: { state: ConversationState } & SearchRenderProps) {
  const searchActive = searchQuery !== "";
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
    // An active search pauses auto-follow so new events don't yank the
    // viewport away from the inspected match; clearing the query restores it.
    if (node && following && !searchActive) {
      scrollToBottom(node.parentElement);
    }
  };

  // Turn boundaries: real (hook-observed turn.started indexes) once hooks are
  // live; items that predate the first real boundary (snapshot history) keep
  // the user_message-derived fallback.
  const realBoundaries = new Set(state.turnStarts);
  const firstRealBoundary =
    state.turnStarts.length > 0 ? Math.min(...state.turnStarts) : Number.POSITIVE_INFINITY;
  const provider = state.session?.provider ?? null;
  const matchedIndexSet = new Set(matchedIndexes);
  const filtering = searchActive && filterMode;
  const rows: ReactNode[] = [];
  state.items.forEach((item, index) => {
    const isMatch = searchActive && matchedIndexSet.has(index);
    if (filtering && !isMatch) {
      return;
    }
    // Turn separators are an unfiltered-timeline concept; the filtered view
    // is a flat match list.
    if (!filtering) {
      const isBoundary =
        index >= firstRealBoundary ? realBoundaries.has(index) : item.type === "user_message";
      if (isBoundary && index > 0) {
        rows.push(<TurnSeparator key={`turn-${item.id}`} />);
      }
    }
    rows.push(
      <ItemRow
        key={item.id}
        item={item}
        provider={provider}
        searchQuery={isMatch ? searchQuery : ""}
        isSearchMatch={isMatch}
        isCurrentSearchMatch={isMatch && item.id === currentMatchId}
      />,
    );
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
        {isAgentWorking(state) ? (
          <output className="agent-chat-row agent-chat-working-row" data-working="true">
            <span className="agent-chat-working-dot" aria-hidden="true" />
            <span className="agent-chat-working-dot" aria-hidden="true" />
            <span className="agent-chat-working-dot" aria-hidden="true" />
            <span className="agent-chat-visually-hidden">{agentChatLabels.agentWorking}</span>
          </output>
        ) : null}
        {state.streamError ? (
          <div className="agent-chat-row agent-chat-system-row is-error" data-stream-error="true">
            <span className="agent-chat-system-label">{agentChatLabels.streamError}</span>
            <span className="agent-chat-system-text">
              {state.streamError.message}
              {state.streamError.recoverable ? agentChatLabels.streamErrorRetrying : ""}
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
          {agentChatLabels.jumpToLatest}
        </button>
      ) : null}
    </div>
  );
}
