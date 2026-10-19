// The hover card of a session reference (a started chat's card or name chip, a session id in a
// reply), the way Claude Code desktop's PR list rows show one: the title, then a line with its state
// (glyph and word in the state's colour, no outline), the project and, at the end, how long ago it
// changed; a session with a pull request adds the PR's status and `repo #N` as its chat card names
// them. A running session's state draws the pane's working spinner bare, with nothing filled behind
// it (Leo, 2026-10-19). The card waits for a short rest
// of the pointer, shows at once for keyboard focus (ArrowDown moves into it, Escape leaves it),
// and a click on it opens the session. Behind the `started-session-cards` experiment.
import {
  createContext,
  type FocusEvent,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
} from "react";
import { Icon } from "../icons/Icon";
import { useT, type StringKey } from "../i18n";
import { Spinner } from "../conversation/icons";
import { shortAge } from "../sessionList";
import { AnchoredCard } from "../../../ui/Tooltip";
import { HOVER_INTENT, HoverGroup, useHoverIntent } from "../../../ui/hoverIntent";
import { type HoverState, type SessionHoverInfo, type SessionHoverStore, useSessionHoverInfo } from "./sessionHover";
import { PR_STATUS_WORDS, pullRequestName } from "./startedSessions";
import "./sessionHover.css";

/// The pointer's rest on a reference before its card shows: shorter than a sidebar row's
/// preview (`HOVER_INTENT.cardDwell`), since a reference in prose is something to read about.
export const SESSION_HOVER_DELAY = 500;

/// Where the cards read sessions from, and how a click opens one. Absent (started session cards
/// off), references draw no card.
export type SessionHover = { store: SessionHoverStore; open(sessionId: string): void };
export const SessionHoverContext = createContext<SessionHover | null>(null);

/// One group for every reference: after one card, the next shows at once while the pointer moves on.
const group = new HoverGroup(HOVER_INTENT.cardGrace);

const LABELS: Record<HoverState, StringKey> = {
  running: "subagents.state.running",
  waiting: "home.needsInput",
  failed: "subagents.state.failed",
  unread: "sidebar.markUnread",
  done: "subagents.state.completed",
};

export type SessionHoverTrigger = {
  onPointerEnter?(event: PointerEvent<HTMLElement>): void;
  onPointerLeave?(): void;
  onPointerDown?(): void;
  onFocus?(event: FocusEvent<HTMLElement>): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
  onKeyDown?(event: KeyboardEvent<HTMLElement>): void;
  "aria-describedby"?: string;
};

/// The hover card of session `sessionId`: spread `trigger` on the reference and render `card`
/// beside it. Both are empty without a ``SessionHoverContext``.
export function useSessionHover(sessionId: string): { trigger: SessionHoverTrigger; card: ReactNode } {
  const hover = useContext(SessionHoverContext);
  const intent = useHoverIntent<HTMLElement>({ delay: SESSION_HOVER_DELAY, group });
  const { hover: point, dismiss } = intent;
  const [placed, setPlaced] = useState<HTMLElement | null>(null);
  const leave = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const inside = useRef<HTMLButtonElement | null>(null);
  // Escape in the card hands focus back to the reference: that focus must not show the card again.
  const returning = useRef(false);
  const cardId = useId();
  useEffect(() => {
    if (intent.shown) setPlaced(intent.shown);
  }, [intent.shown]);
  useEffect(() => () => clearTimeout(leave.current), []);
  if (!hover) return { trigger: {}, card: null };

  const stay = () => {
    clearTimeout(leave.current);
    leave.current = undefined;
  };
  // The pointer or focus left the reference or its card: the card goes after the grace, unless
  // it comes back to either, or focus is still on one of them (the pointer drifting off a card
  // the keyboard opened).
  const go = () => {
    stay();
    leave.current = setTimeout(() => {
      leave.current = undefined;
      if (ownsFocus(document.activeElement)) return;
      point(null);
    }, HOVER_INTENT.cardGrace);
  };
  const now = () => {
    stay();
    dismiss();
  };
  const ownsFocus = (target: EventTarget | null) =>
    target instanceof Node && (inside.current?.contains(target) || placed?.contains(target));
  const trigger: SessionHoverTrigger = {
    onPointerEnter: (event) => {
      stay();
      point(event.currentTarget);
    },
    onPointerLeave: go,
    onPointerDown: now,
    onFocus: (event) => {
      stay();
      if (returning.current) {
        returning.current = false;
        return;
      }
      point(event.currentTarget, 0);
    },
    onBlur: (event) => {
      if (!ownsFocus(event.relatedTarget)) go();
    },
    // ui-allow: Escape puts the card away and ArrowDown moves focus into it; Enter stays the reference's own.
    onKeyDown: (event) => {
      if (event.key === "Escape" && intent.shown) {
        event.stopPropagation();
        now();
      } else if (event.key === "ArrowDown" && intent.shown && inside.current) {
        event.preventDefault();
        inside.current.focus();
      }
    },
    ...(intent.shown ? { "aria-describedby": cardId } : {}),
  };
  const card = placed ? (
    <AnchoredCard
      id={cardId}
      anchor={placed}
      open={intent.shown !== null}
      instant={intent.instant}
      interactive
      ariaLabel={hover.store.get(sessionId)?.title}
      className="acpmux-session-hover-card"
      onPointerEnter={stay}
      onPointerLeave={go}
    >
      <SessionHoverBody
        store={hover.store}
        sessionId={sessionId}
        buttonRef={inside}
        onOpen={() => {
          now();
          hover.open(sessionId);
        }}
        onEscape={() => {
          now();
          returning.current = true;
          placed.focus();
          returning.current = false;
        }}
        onBlur={(event) => {
          if (!ownsFocus(event.relatedTarget)) go();
        }}
        onFocus={stay}
      />
    </AnchoredCard>
  ) : null;
  return { trigger, card };
}

function SessionHoverBody({
  store,
  sessionId,
  buttonRef,
  onOpen,
  onEscape,
  onBlur,
  onFocus,
}: {
  store: SessionHoverStore;
  sessionId: string;
  buttonRef: { current: HTMLButtonElement | null };
  onOpen(): void;
  onEscape(): void;
  onBlur(event: FocusEvent<HTMLElement>): void;
  onFocus(): void;
}) {
  const info = useSessionHoverInfo(store, sessionId);
  if (!info) return null;
  return (
    <SessionHoverContent
      info={info}
      buttonRef={buttonRef}
      onOpen={onOpen}
      onEscape={onEscape}
      onBlur={onBlur}
      onFocus={onFocus}
    />
  );
}

/// The card's content: the whole card is one button that opens the session.
export function SessionHoverContent({
  info,
  now = Date.now(),
  buttonRef,
  onOpen,
  onEscape,
  onBlur,
  onFocus,
}: {
  info: SessionHoverInfo;
  now?: number;
  buttonRef?: { current: HTMLButtonElement | null };
  onOpen(): void;
  onEscape?(): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
  onFocus?(): void;
}) {
  const t = useT();
  const age = shortAge(info.updatedAt, now, t);
  return (
    <button
      ref={(element) => {
        if (buttonRef) buttonRef.current = element;
      }}
      type="button"
      className="acpmux-session-hover"
      data-state={info.state}
      onClick={onOpen}
      onBlur={onBlur}
      onFocus={onFocus}
      // ui-allow: Escape hands focus back to the reference the card belongs to.
      onKeyDown={(event) => {
        if (event.key !== "Escape" || !onEscape) return;
        event.stopPropagation();
        onEscape();
      }}
    >
      <span className="acpmux-session-hover-title">{info.title}</span>
      <span className="acpmux-session-hover-meta">
        <SessionStateLabel state={info.state} />
        {info.project && <span className="acpmux-session-hover-project">{info.project}</span>}
        {age && <span className="acpmux-session-hover-age">{age}</span>}
      </span>
      {info.pullRequests && <PullRequestRow pullRequests={info.pullRequests} />}
    </button>
  );
}

/// The state: its glyph and its name in the state's colour. Running draws the bare spinner.
export function SessionStateLabel({ state }: { state: HoverState }) {
  const t = useT();
  return (
    <span className="acpmux-session-state" data-state={state}>
      {state === "running" ? (
        <Spinner size={11} className="acpmux-session-state-spinner" />
      ) : (
        <Icon name={GLYPHS[state]} size={11} />
      )}
      {t(LABELS[state])}
    </span>
  );
}

/// The session's pull request: its status in its colour, then `repo #N` (and how many more).
function PullRequestRow({ pullRequests }: { pullRequests: NonNullable<SessionHoverInfo["pullRequests"]> }) {
  const t = useT();
  const word = PR_STATUS_WORDS[pullRequests.tone];
  return (
    <span className="acpmux-session-hover-pr">
      <span className="acpmux-session-hover-pr-status" data-tone={pullRequests.tone}>
        <Icon name="git.pullrequest" size={11} />
        {word && <span>{t(word)}</span>}
      </span>
      <span className="acpmux-session-hover-pr-name">{pullRequestName(pullRequests)}</span>
      {pullRequests.count > 1 && <span>{t("started.morePullRequests", { count: pullRequests.count - 1 })}</span>}
    </span>
  );
}

const GLYPHS = {
  waiting: "status.needsinput",
  failed: "status.error",
  unread: "status.dot",
  done: "status.complete",
} as const satisfies Record<Exclude<HoverState, "running">, string>;
