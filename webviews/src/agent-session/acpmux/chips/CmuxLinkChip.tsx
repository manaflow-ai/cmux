// A pasted cmux link (Copy Link to Workspace, a chat's link) drawn as what it names: the session
// link chip's wash with the kind's icon and the title, and the machine when it is another one
// (Leo, 2026-11-08: "it should be able to render in the box that it is an actual chat that is
// there, like with the title and whatever, and, like, to be potentially hoverable as well, instead
// of just being, like, you know, here's the raw URL"). What it names comes from the page's stores
// (cmuxLinkResolve.ts); until something names it, and for an id nothing names (closed, deleted,
// another person's), it is `fallback`, the link as before. The text sent and copied stays the link.
//
// Hover: a chat the list has shows its session card (started/SessionHoverCard.tsx), as a sent
// message's recipient does; a workspace, pane or tab shows the link card (LinkHoverCard.tsx's
// look: its icon, its title, its kind and place, then the link). Click: a chat opens as its link did
// before the chips (ChatLinkChip below: `chat.offer.open`), anything else through the host's link
// path (`link.open`), which the anchor's own click takes.
import { useContext, useState, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { experimentArm } from "../../../experiments/experiment";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { openSessionAttributes } from "../conversation/menuParts";
import { SessionHoverContext } from "../started/sessionHoverCardModel";
import { useSessionHover } from "../started/useSessionHover";
import { chatUnderHoverCard, hoverCardGlass } from "../chatUnderGlass";
import { useHoverCard } from "./useHoverCard";
import { useCmuxLink, type CmuxLinkInfo, type CmuxLinkKind } from "./cmuxLinkResolve";
import { namesChat, type CmuxLinkTarget } from "../conversation/cmuxLinks";
import { useAgentLinkClick } from "../conversation/SessionRef";
import { SubsessionContext } from "../subagents/subsessions";
import { cmuxLinkLook, type CmuxLinkLook } from "./cmuxLinkLook.experiment";
import "./linkCard.css";
import "./cmuxLinkChip.css";

/// The icon of each kind (the cmux pack's names).
export const CMUX_LINK_ICONS: Record<CmuxLinkKind, string> = {
  chat: "agent.chat",
  workspace: "workspace",
  pane: "view.tab.trailing",
  tab: "view.tab.trailing",
};

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
export function CmuxLinkLabel({ info, look }: { info: CmuxLinkInfo; look: CmuxLinkLook }) {
  const kindWord = useKindWord();
  if (look === "kind-title")
    return (
      <>
        <span className="cv-cmux-link__kind">{kindWord(info.kind)} ·</span>
        <span className="cv-cmux-link__title">{info.title}</span>
      </>
    );
  return (
    <>
      <Icon name={CMUX_LINK_ICONS[info.kind]} size={14} className="cv-cmux-link__icon" />
      <span className="cv-cmux-link__title">{info.title}</span>
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

export function CmuxLinkChip({ href, fallback, look }: { href: string; fallback: ReactNode; look?: CmuxLinkLook }) {
  const { target, info } = useCmuxLink(href);
  const shown = look ?? experimentArm(cmuxLinkLook);
  if (!target || !info || shown === "link") return <>{fallback}</>;
  return namesChat(target) ? (
    <ChatLinkChip href={href} target={target} info={info} look={shown} />
  ) : (
    <PlaceLinkChip href={href} info={info} look={shown} />
  );
}

/// A chat's chip. Its click is the link's own from before the chips (review of #38166, F1): an agent
/// link (`cmux://agent/…`, cmux.com's) opens as a bare agent link's chip does (`useAgentLinkClick`,
/// `chat.offer.open` as a sender, the chat acpmux resolves, a peer's included; its web page or the
/// host's link path when it is not the reader's); a session or Chief link opens its listed chat
/// (`chat.offer.open`), and one to a turn takes the host's link path, which shows the turn.
function ChatLinkChip({
  href,
  target,
  info,
  look,
}: {
  href: string;
  target: Extract<CmuxLinkTarget, { kind: "session" | "chief" | "agent" }>;
  info: CmuxLinkInfo;
  look: CmuxLinkLook;
}) {
  const hover = useContext(SessionHoverContext);
  const subsessions = useContext(SubsessionContext);
  const readOnly = useTranscriptReadOnly();
  const open = readOnly ? undefined : hover?.open;
  const agent = useAgentLinkClick(target.kind === "agent" ? href : "");
  const agentOpens = agent.onClick !== undefined;
  const sessionId = info.sessionId;
  const cardOpen = agentOpens ? (subsessions?.openSender ?? subsessions?.open) : open;
  const { trigger, card } = useSessionHover(sessionId ?? "", cardOpen);
  const turn = target.kind === "session" && target.turn !== undefined;
  const onClick = (event: ReactMouseEvent<HTMLAnchorElement>) => {
    if (agentOpens) return agent.onClick!(event);
    if (!open || !sessionId || turn || event.defaultPrevented) return;
    event.preventDefault();
    open(sessionId);
  };
  const menu = agentOpens
    ? {
        "data-open-session": agent["data-open-session"],
        "data-open-session-sender": agent["data-open-session-sender"],
      }
    : open && sessionId
      ? openSessionAttributes(sessionId)
      : {};
  return (
    <>
      <a
        {...trigger}
        className="cv-cmux-link acpmux-started-chip"
        href={href}
        rel="noreferrer"
        data-cmux-link="chat"
        data-look={look}
        {...menu}
        onPointerEnter={(event) => {
          agent.onPointerEnter?.();
          trigger.onPointerEnter?.(event);
        }}
        onFocus={(event) => {
          agent.onFocus?.();
          trigger.onFocus?.(event);
        }}
        onClick={onClick}
      >
        <CmuxLinkLabel info={info} look={look} />
      </a>
      {card}
    </>
  );
}

function PlaceLinkChip({ href, info, look }: { href: string; info: CmuxLinkInfo; look: CmuxLinkLook }) {
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  const line = usePlaceLine(info);
  return (
    <>
      <a
        ref={setAnchor}
        // The anchor's click takes the host's link path, which opens it in the app (`link.open`).
        className="cv-cmux-link acpmux-started-chip"
        href={href}
        rel="noreferrer"
        data-cmux-link={info.kind}
        data-look={look}
        {...hover.trigger}
      >
        <CmuxLinkLabel info={info} look={look} />
      </a>
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
    </>
  );
}
