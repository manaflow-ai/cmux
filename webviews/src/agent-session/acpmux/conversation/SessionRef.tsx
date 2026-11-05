// An agent session reference in a reply's inline code (sessionRefs.ts): an agent link draws as a
// link that opens the session's chat when it is the reader's own or shared with them (the daemon
// resolves it), and its web page otherwise; a `HOST/NAME` draws as plain code until the daemon
// says it is a session, then as the session link chip a sender's name is (AgentTag.tsx), opening
// the chat the same way (`chat.offer.open` with `sender`, App.tsx `openSenderChat`). Once either
// names one of the reader's chats it is that chat's reference: its hover card says the chat's state,
// what it does now, its place, pull request and last change (started/SessionHoverCard.tsx), and its
// right-click menu is the chat's (menuParts.ts `session`).
import {
  useContext,
  useEffect,
  useMemo,
  useSyncExternalStore,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from "react";
import { useT } from "../i18n";
import { SubsessionContext } from "../subagents/subsessions";
import { useTranscriptReadOnly } from "./readOnly";
import { SoftBroken } from "./softBreaks";
import {
  agentRef,
  knownSessionRef,
  resolveSessionRef,
  sessionRefsResolve,
  subscribeSessionRefs,
  whenIdle,
  type AgentRef,
  type SessionRefTarget,
} from "./sessionRefs";
import { openSessionAttributes } from "./menuParts";
import { useSessionHover } from "../started/SessionHoverCard";

const noStore = () => () => {};
const NO_PROPS: Partial<ReturnType<typeof agentLinkProps>> = {};

/// The session `query` names: a listed chat's id by name at once (no ask), else the daemon's
/// cached answer (a received line's unlisted sender reads it too, IncomingMessageCard.tsx).
export function useSessionRef(query: string | undefined, byName: boolean): SessionRefTarget | null | undefined {
  const store = useContext(SubsessionContext)?.store;
  const readListed = () => (byName && query ? store?.find(query) : undefined);
  const listed = useSyncExternalStore(store?.subscribeNames ?? noStore, readListed, readListed);
  const readKnown = () => (query ? knownSessionRef(query) : null);
  const known = useSyncExternalStore(subscribeSessionRefs, readKnown, readKnown);
  return listed ? { sessionId: listed } : known;
}

function useOpenTitle(target: SessionRefTarget | null | undefined, text: string): string | undefined {
  const t = useT();
  if (!target) return undefined;
  const name = target.name ?? text;
  return target.host ? t("subagents.openOnHost", { name, host: target.host }) : t("subagents.open", { name });
}

export function SessionRefCode({
  text,
  agentRef,
  fallback,
}: {
  text: string;
  agentRef: AgentRef;
  fallback: ReactNode;
}) {
  const subsessions = useContext(SubsessionContext);
  const readOnly = useTranscriptReadOnly();
  const open = subsessions?.openSender ?? subsessions?.open;
  // A reader who may not open chats here (a guest) or a page with no daemon resolves nothing.
  const live = !readOnly && open !== undefined && sessionRefsResolve();
  const query = live ? agentRef.query : undefined;
  const target = useSessionRef(query, agentRef.kind === "name");
  const title = useOpenTitle(target, text);

  // A name is resolved once the page is idle, once per name for the whole page.
  const pendingName = agentRef.kind === "name" && query !== undefined && target === undefined;
  useEffect(
    () => (pendingName && query ? whenIdle(() => void resolveSessionRef(query)) : undefined),
    [pendingName, query],
  );

  const sender = subsessions?.openSender !== undefined;
  const { trigger, card } = useSessionHover(target?.sessionId ?? "");
  const hover = target ? trigger : {};
  // With its hover card (a page with session hover), the native tooltip would cover it.
  const carded = target !== null && target !== undefined && trigger.onPointerEnter !== undefined;

  if (agentRef.kind === "name") {
    if (!target || !open) return <>{fallback}</>;
    return (
      <>
        <button
          {...hover}
          type="button"
          className="acpmux-started-chip cv-session-ref"
          title={carded ? undefined : title}
          aria-label={title}
          data-session-ref=""
          // The click opens it as a sender (`openSender`) where the page has one; the menu asks the same way.
          {...openSessionAttributes(target.sessionId, sender)}
          onClick={() => open(target.sessionId)}
        >
          <code className="cv-code">
            <SoftBroken text={text} />
          </code>
        </button>
        {card}
      </>
    );
  }

  const link = agentLinkProps(query, target, open, sender);
  return (
    <>
      <a
        className="cv-link cv-session-ref"
        href={agentRef.href}
        rel="noreferrer"
        title={carded ? undefined : title}
        aria-label={carded ? title : undefined}
        {...hover}
        {...link}
        onPointerEnter={(event) => {
          link.onPointerEnter?.();
          hover.onPointerEnter?.(event);
        }}
        onFocus={(event) => {
          link.onFocus?.();
          hover.onFocus?.(event);
        }}
      >
        <code className="cv-code">
          <SoftBroken text={text} />
        </code>
      </a>
      {target && card}
    </>
  );
}

/// The handlers that make an agent link open the reader's own session (`target` resolved, or
/// resolved on the click), and follow the link otherwise. `query` undefined: none.
function agentLinkProps(
  query: string | undefined,
  target: SessionRefTarget | null | undefined,
  open: ((sessionId: string) => void) | undefined,
  sender = false,
) {
  const prefetch = query && target === undefined ? () => void resolveSessionRef(query) : undefined;
  const onClick = (event: ReactMouseEvent<HTMLAnchorElement>) => {
    if (!query || !open || event.defaultPrevented) return;
    // Read now, not from the render: a click this link dispatched itself follows an answer.
    const now = knownSessionRef(query);
    if (now === null) return; // Not the reader's: its web page opens.
    if (now) {
      event.preventDefault();
      return open(now.sessionId);
    }
    // Not asked yet: ask, then open the chat, or follow the link as a click would have.
    event.preventDefault();
    const anchor = event.currentTarget;
    void resolveSessionRef(query).then((found) => {
      if (found) open(found.sessionId);
      else {
        const View = anchor.ownerDocument.defaultView?.MouseEvent ?? MouseEvent;
        anchor.dispatchEvent(new View("click", { bubbles: true, cancelable: true }));
      }
    });
  };
  return {
    "data-session-ref": target ? "" : undefined,
    // Once it names the reader's chat, its right-click is that chat's menu, its link rows kept.
    ...(target && open ? openSessionAttributes(target.sessionId, sender) : {}),
    onPointerEnter: prefetch,
    onFocus: prefetch,
    onClick,
  };
}

/// An agent link drawn elsewhere (a bare URL's chip, chips/LinkChips.tsx UrlChip): the same
/// open-or-follow click; nothing for any other link.
export function useAgentLinkClick(href: string) {
  const subsessions = useContext(SubsessionContext);
  const readOnly = useTranscriptReadOnly();
  const open = subsessions?.openSender ?? subsessions?.open;
  const ref = useMemo(() => agentRef(href), [href]);
  const live = !readOnly && open !== undefined && sessionRefsResolve() && ref?.kind === "link";
  const query = live ? ref.query : undefined;
  const target = useSessionRef(query, false);
  return query ? agentLinkProps(query, target, open, subsessions?.openSender !== undefined) : NO_PROPS;
}
