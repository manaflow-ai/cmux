import { useContext, useMemo, useSyncExternalStore, type MouseEvent as ReactMouseEvent } from "react";
import { SubsessionContext } from "../subagents/subsessions";
import { useTranscriptReadOnly } from "./readOnly";
import { openSessionAttributes } from "./menuParts";
import {
  agentRef,
  knownSessionRef,
  resolveSessionRef,
  sessionRefsResolve,
  subscribeSessionRefs,
  type SessionRefTarget,
} from "./sessionRefs";

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

/// The handlers that make an agent link open the reader's own session (`target` resolved, or
/// resolved on the click), and follow the link otherwise. `query` undefined: none.
export function agentLinkProps(
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
