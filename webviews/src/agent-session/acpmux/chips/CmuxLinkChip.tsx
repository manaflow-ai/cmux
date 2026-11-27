// A pasted cmux link (Copy Link to Workspace, a chat's link) drawn as what it names: the session
// link chip's wash with the kind's icon and the title, and the machine when it is another one
// (Leo, 2026-11-08: "it should be able to render in the box that it is an actual chat that is
// there, like with the title and whatever, and, like, to be potentially hoverable as well, instead
// of just being, like, you know, here's the raw URL"). What it names comes from the page's stores
// (cmuxLinkResolve.ts); until something names it, and for an id nothing names (closed, deleted,
// another person's), it is `fallback`, the link as before. The text sent and copied stays the link.
//
// Hover: a chat the list has shows its session card (started/SessionHoverCard.tsx), as a sent
// message's recipient does; a chat only acpmux resolved (a peer's, which the list does not have),
// a workspace, a pane or a tab shows the link card (LinkHoverCard.tsx's look: its icon, its title,
// its kind and place, then the link), from what the resolve or the host's push named. Click: what the plain link's was
// before the chips, for every kind: an app link takes the host's link path (`link.open`), which the
// anchor's own click takes; cmux.com's agent link opens as its URL chip did (ChatLinkChip below).
// Copy: a selection copies each chip as its link (conversation/selectionCopy.ts).
//
// A Markdown link (`[label](cmux://…)`) passes its `label`: the chip draws the author's words in
// place of the title (the card still names the title), and copies as the label it shows, as its
// plain anchor did.
import { useContext, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { experimentArm } from "../../../experiments/experiment";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { useSessionHover } from "../started/useSessionHover";
import { SessionHoverContext } from "../started/sessionHoverCardModel";
import { chatUnderHoverCard, hoverCardGlass } from "../chatUnderGlass";
import { useHoverCard, type HoverCard } from "./useHoverCard";
import { CMUX_LINK_ICONS, useCmuxLink, type CmuxLinkInfo, type CmuxLinkKind } from "./cmuxLinkResolve";

export { CMUX_LINK_ICONS };
import { namesChat, type CmuxLinkTarget } from "../conversation/cmuxLinks";
import { useAgentLinkClick } from "../conversation/sessionRefModel";
import { SubsessionContext } from "../subagents/subsessions";
import { installSelectionCopy } from "../conversation/selectionCopy";
import { cmuxLinkLook, type CmuxLinkLook } from "./cmuxLinkLook.experiment";
import "./linkCard.css";
import "./cmuxLinkChip.css";

const KIND_KEYS = {
  chat: "cmuxLink.kind.chat",
  workspace: "cmuxLink.kind.workspace",
  pane: "cmuxLink.kind.pane",
  tab: "cmuxLink.kind.tab",
} as const;

/// The kind word of `kind`, in the pane's language.
export function useKindWord(): (kind: CmuxLinkKind) => string {
  const t = useT();
  return (kind) => t(KIND_KEYS[kind]);
}

/// The chip's content in `look`: the icon, the title and the machine, or the kind word and title.
/// `label`: a Markdown link's own words, drawn in the title's place.
export function CmuxLinkLabel({ info, look, label }: { info: CmuxLinkInfo; look: CmuxLinkLook; label?: ReactNode }) {
  const kindWord = useKindWord();
  const title = label ?? info.title;
  if (look === "kind-title")
    return (
      <>
        <span className="cv-cmux-link__kind">{kindWord(info.kind)} ·</span>
        <span className="cv-cmux-link__title">{title}</span>
      </>
    );
  return (
    <>
      <Icon name={CMUX_LINK_ICONS[info.kind]} size={14} className="cv-cmux-link__icon" />
      <span className="cv-cmux-link__title">{title}</span>
      {look === "icon-title-host" && info.host && <span className="cv-cmux-link__host">{info.host}</span>}
    </>
  );
}

/// The line under a place's title in its card: its kind, and where it is.
function usePlaceLine(info: CmuxLinkInfo): string {
  const t = useT();
  const kind = useKindWord()(info.kind);
  if (info.workspace) return t("cmuxLink.inWorkspace", { kind, workspace: info.workspace });
  if (info.host) return t("cmuxLink.onHost", { kind, host: info.host });
  return kind;
}

export function CmuxLinkChip({
  href,
  fallback,
  look,
  label,
}: {
  href: string;
  fallback: ReactNode;
  look?: CmuxLinkLook;
  /// A Markdown link's label (`[label](cmux://…)`): the chip keeps the author's words.
  label?: ReactNode;
}) {
  const { target, info } = useCmuxLink(href);
  const shown = look ?? experimentArm(cmuxLinkLook);
  const chip = Boolean(target && info && shown !== "link");
  // A selection copies the chip as its link, in a prompt's text too (conversation/selectionCopy.ts).
  if (chip) installSelectionCopy();
  return (
    <LinkSlot swap={chip ? "chip" : "link"}>
      {!target || !info || shown === "link" ? (
        fallback
      ) : namesChat(target) ? (
        <ChatLinkChip href={href} target={target} info={info} look={shown} label={label} />
      ) : (
        <PlaceLinkChip href={href} info={info} look={shown} label={label} />
      )}
    </LinkSlot>
  );
}

/// The link and its chip are different elements (the caller's link, the chip once something names
/// it), so the anchor is replaced when the answer comes. This box, which draws nothing
/// (`display: contents`), stays: focus or the pointer on the link when it is replaced moves to the
/// new anchor, so a link tabbed to before its answer still takes Enter and its card follows the
/// pointer (review of #38166), as a URL chip that resolves in place does.
function LinkSlot({ swap, children }: { swap: "chip" | "link"; children: ReactNode }) {
  const [slot, setSlot] = useState<HTMLSpanElement | null>(null);
  const held = useRef({ focused: false, hovered: false });
  useEffect(() => {
    if (!slot) return;
    const state = held.current;
    const focusIn = () => void (state.focused = true);
    // Read after the event: a replaced anchor's blur comes while the new one is not in yet, and the
    // swap's layout effect, in the same task, still sees the focus as here.
    const focusOut = () => queueMicrotask(() => void (state.focused = slot.contains(slot.ownerDocument.activeElement)));
    const over = () => void (state.hovered = true);
    const leave = () => void (state.hovered = false);
    slot.addEventListener("focusin", focusIn);
    slot.addEventListener("focusout", focusOut);
    slot.addEventListener("pointerover", over);
    slot.addEventListener("pointerleave", leave);
    return () => {
      slot.removeEventListener("focusin", focusIn);
      slot.removeEventListener("focusout", focusOut);
      slot.removeEventListener("pointerover", over);
      slot.removeEventListener("pointerleave", leave);
    };
  }, [slot]);
  const shownOnce = useRef(swap);
  useLayoutEffect(() => {
    if (shownOnce.current === swap) return;
    shownOnce.current = swap;
    const anchor = slot?.querySelector<HTMLAnchorElement>("a[href]");
    if (!slot || !anchor) return;
    const owner = slot.ownerDocument;
    const lost = !owner.activeElement || owner.activeElement === owner.body;
    if (held.current.focused && lost) anchor.focus({ preventScroll: true });
    else if (held.current.hovered && !held.current.focused) {
      // The new anchor's hover, as the pointer arriving on it (its card's own enter).
      const box = anchor.getBoundingClientRect();
      const at = { bubbles: true, clientX: (box.left + box.right) / 2, clientY: (box.top + box.bottom) / 2 };
      anchor.dispatchEvent(new PointerEvent("pointerover", at));
      anchor.dispatchEvent(new PointerEvent("pointerenter", { ...at, bubbles: false }));
    }
  }, [swap, slot]);
  return (
    <span ref={setSlot} className="cv-cmux-link-slot">
      {children}
    </span>
  );
}

/// A chat's chip. Its click is exactly the plain link's from before the chips (review of #38166, F1,
/// F2): an app link (`cmux://session/…`, a turn, a Chief chat, a native agent link with its
/// `?message=`) is not touched, so the anchor takes the host's link path (`link.open`), which opens
/// any chat it names and reveals the turn or message; cmux.com's agent link opens as its URL chip did
/// (`useAgentLinkClick`: the reader's own chat as a sender, else its web page). The card's click does
/// what the chip's does: it follows the link for an app link, and opens as the URL chip's card did for
/// a web one. A chat the list does not have (a peer's, named by acpmux's resolve) has no session
/// card: it shows the link card from what the resolve named, its name, machine and link (review of
/// #38166: a peer's chip had no card at all).
function ChatLinkChip({
  href,
  target,
  info,
  look,
  label,
}: {
  href: string;
  target: Extract<CmuxLinkTarget, { kind: "session" | "chief" | "agent" }>;
  info: CmuxLinkInfo;
  look: CmuxLinkLook;
  label?: ReactNode;
}) {
  const subsessions = useContext(SubsessionContext);
  const web = target.kind === "agent" && target.web;
  const agent = useAgentLinkClick(web ? href : "");
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  const follow = () => anchor?.click();
  const cardOpen = web ? (subsessions?.openSender ?? subsessions?.open) : anchor ? follow : undefined;
  const { trigger: sessionTrigger, card: sessionCard } = useSessionHover(info.sessionId ?? "", cardOpen);
  const hoverStore = useContext(SessionHoverContext)?.store;
  const readListed = () => Boolean(hoverStore && info.sessionId && hoverStore.get(info.sessionId));
  const listed = useSyncExternalStore(hoverStore?.subscribe ?? noStore, readListed, readListed);
  const peer = useHoverCard();
  const trigger = listed ? sessionTrigger : peer.trigger;
  // The list naming the chat later swaps the link card for its session card: the link card's open
  // state goes with it, so the chat leaving the list again does not bring it back unasked.
  const dismissPeer = peer.dismiss;
  useEffect(() => {
    if (listed) dismissPeer();
  }, [listed, dismissPeer]);
  return (
    <>
      <a
        ref={setAnchor}
        {...trigger}
        className="cv-cmux-link acpmux-started-chip"
        href={href}
        rel="noreferrer"
        data-cmux-link="chat"
        data-cmux-link-label={label === undefined ? undefined : ""}
        data-look={look}
        data-session-ref={agent["data-session-ref"]}
        // A web link to one of the reader's chats right-clicks as that chat, as its URL chip did.
        data-open-session={agent["data-open-session"]}
        data-open-session-sender={agent["data-open-session-sender"]}
        onPointerEnter={(event) => {
          agent.onPointerEnter?.();
          trigger.onPointerEnter?.(event);
        }}
        onFocus={(event) => {
          agent.onFocus?.();
          trigger.onFocus?.(event);
        }}
        onClick={agent.onClick}
      >
        <CmuxLinkLabel info={info} look={look} label={label} />
      </a>
      {listed ? sessionCard : <LinkCard hover={peer} anchor={anchor} href={href} info={info} />}
    </>
  );
}

const noStore = () => () => {};

function PlaceLinkChip({
  href,
  info,
  look,
  label,
}: {
  href: string;
  info: CmuxLinkInfo;
  look: CmuxLinkLook;
  label?: ReactNode;
}) {
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  return (
    <>
      <a
        ref={setAnchor}
        // The anchor's click takes the host's link path, which opens it in the app (`link.open`).
        className="cv-cmux-link acpmux-started-chip"
        href={href}
        rel="noreferrer"
        data-cmux-link={info.kind}
        data-cmux-link-label={label === undefined ? undefined : ""}
        data-look={look}
        {...hover.trigger}
      >
        <CmuxLinkLabel info={info} look={look} label={label} />
      </a>
      <LinkCard hover={hover} anchor={anchor} href={href} info={info} />
    </>
  );
}

/// The link card of a place, or of a chat only acpmux resolved: its kind's icon, its title, its kind
/// and where it is, then the link as pasted.
function LinkCard({
  hover,
  anchor,
  href,
  info,
}: {
  hover: HoverCard;
  anchor: HTMLAnchorElement | null;
  href: string;
  info: CmuxLinkInfo;
}) {
  const line = usePlaceLine(info);
  return (
    <AnchoredCard
      anchor={hover.open ? anchor : null}
      className="ui-glass ui-glass-floats cv-link-preview cv-cmux-link-card"
      instant
      interactive
      hoverBridgeId={hover.card["data-cmux-hover-bridge"]}
      under={chatUnderHoverCard}
      underOptions={hoverCardGlass}
      onPointerEnter={hover.card.onPointerEnter}
      onPointerLeave={hover.card.onPointerLeave}
      ariaLabel={info.title}
    >
      <div className="cv-link-preview__content" {...hover.card}>
        <div className="cv-link-preview__head">
          <span className="cv-link-preview__icon">
            <Icon name={CMUX_LINK_ICONS[info.kind]} size={16} />
          </span>
          <span className="cv-link-preview__titles">
            <span className="cv-link-preview__site">{info.title}</span>
            <span className="cv-link-preview__target">{line}</span>
          </span>
        </div>
        <div className="cv-cmux-link-card__link">{href}</div>
      </div>
    </AnchoredCard>
  );
}
