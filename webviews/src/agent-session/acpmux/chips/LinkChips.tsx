// Link and path chips in replies (decision D4): an icon, the name with a dotted underline, and
// the full address in the tooltip. A path chip asks the host where its path is (`link.inspect`)
// and opens through the host (`link.openPath`: the deny list and the session's folders after
// symlinks, then a user gesture; outside the folders, `agentPane.links.outsideRoots` decides and
// the host's own sheet asks). A web chip is an ordinary link, which the host opens outside the
// pane after a real click. It reads as plain link text (Claude Code desktop's links): a local or
// private address never dressed as a site, and a secret-looking query value as `•••`
// (linkDisplay.ts). A chip's text and icon are fixed when it first draws: a site's or a pull
// request's title arriving later never widens it and reflows the paragraph under the reader (Leo
// 2026-10-21, #22896 grew into "#22896 · cmux-next updates: …" after a hover). Titles and favicons
// live in the shared link card (LinkHoverCard.tsx) that hovering opens: Open and Open in, and a
// pull request's title, state, author and checks.
import { useContext, useLayoutEffect, useState, type FocusEvent, type PointerEvent, type ReactNode } from "react";
import { useT } from "../i18n";
import { callChipHost } from "./host";
import { useMessageScope } from "./messageScope";
import { Folder, GitHubMark, Globe, Lock } from "../conversation/icons";
import { FileKindIcon } from "./FileKindIcon";
import { usePathInfo, useSiteInfo } from "./linkStore";
import { isPrivateUrl, redactUrlText } from "./linkDisplay";
import { isDeniedPath, pathName } from "./paths";
import { useReplyFolders } from "./replyFolders";
import { LinkHoverCard } from "./LinkHoverCard";
import { githubItemRef } from "./pullRequestCardModel";
import { usePullRequestState } from "./pullRequestStore";
import { useHoverCard } from "./useHoverCard";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { useAgentLinkClick } from "../conversation/sessionRefModel";
import { githubRefLabel, githubRefTitle } from "./linkChipsModel";
import { useSessionHover } from "../started/useSessionHover";
import { SubsessionContext } from "../subagents/subsessions";

/// A path chip. `label` is the link's text, else the file name; `written` is the reply's own
/// text, which a path that gets no chip draws as.
export function PathChip({ path, label, written }: { path: string; label?: ReactNode; written?: string }) {
  const scope = useMessageScope();
  const readOnly = useTranscriptReadOnly();
  if (isDeniedPath(path)) return <span className="cv-chip-plain">{written ?? label ?? path}</span>;
  // Another machine's file: never asked about or opened here (chips/messageScope.ts). A read-only
  // reader's every path is on the owner's machine.
  if (scope?.host !== undefined || readOnly)
    return <ElsewhereChip path={path} host={scope?.host ?? ""} label={label} />;
  return <HostPathChip path={path} label={label} written={written} />;
}

function HostPathChip({ path, label, written }: { path: string; label?: ReactNode; written?: string }) {
  const t = useT();
  const { info, policy } = usePathInfo(path);
  const plain =
    info?.place === "denied" ||
    info?.place === "missing" ||
    (info?.place === "outside" && policy.outsideRoots === "text");
  if (plain) return <span className="cv-chip-plain">{written ?? label ?? path}</span>;
  const outside = info?.place === "outside";
  const folder = info?.folder ?? path.endsWith("/");
  return (
    <button
      type="button"
      className={`cv-chip is-path${outside ? " is-outside" : ""}`}
      data-path={path}
      /* tooltip-allow: the label omits the full path and the outside-project boundary */
      title={outside ? `${t("chip.outsideProject")}\n${path}` : path}
      /* It drags out as the file itself (conversation/dragOut.ts). */
      draggable
      onClick={() => void callChipHost("link.openPath", { path })}
    >
      {folder ? <Folder size={16} className="cv-chip__icon" /> : <FileKindIcon path={path} className="cv-chip__icon" />}
      <span className="cv-chip__label">{label ?? pathName(path)}</span>
    </button>
  );
}

/// A bare file name in a reply (`chromium-fixed-opaque.png`): the path chip of that file in the
/// first folder the reply names (replyFolders.ts) where the host finds it, else `fallback` (the
/// name as written). Never guessed: another machine's message or a read-only reader asks nothing,
/// and a folder or a missing, denied or text-only file stays as written.
export function SiblingFileChip({
  name,
  folders,
  fallback,
}: {
  name: string;
  folders?: readonly string[];
  fallback?: ReactNode;
}) {
  const reply = useReplyFolders();
  const scope = useMessageScope();
  const readOnly = useTranscriptReadOnly();
  const candidates = folders ?? reply;
  if (!candidates.length || scope?.host !== undefined || readOnly) return fallback ?? name;
  return <FolderFileChip name={name} folders={candidates} fallback={fallback ?? name} />;
}

function FolderFileChip({
  name,
  folders,
  fallback,
}: {
  name: string;
  folders: readonly string[];
  fallback: ReactNode;
}) {
  const path = `${folders[0]}${name}`;
  const { info, answered, policy } = usePathInfo(path);
  const found =
    !isDeniedPath(path) &&
    !info?.folder &&
    (info?.place === "root" || (info?.place === "outside" && policy.outsideRoots !== "text"));
  if (found) return <PathChip path={path} written={name} />;
  // Asked and not there: the next folder the reply names.
  if (answered && folders.length > 1)
    return <FolderFileChip name={name} folders={folders.slice(1)} fallback={fallback} />;
  return fallback;
}

/// A file on the machine an agent's message came from: its name, the path and the
/// machine in its tooltip. Not a button: this Mac has no way to it.
export function ElsewhereChip({ path, host, label }: { path: string; host: string; label?: ReactNode }) {
  const t = useT();
  const where = host ? t("message.fileOnHost", { host, path }) : t("message.fileElsewhere", { path });
  return (
    <span
      className="cv-chip is-path is-elsewhere"
      data-path={path}
      /* tooltip-allow: the chip shows the file's name only; the tooltip says where it is */ title={where}
      aria-label={where}
    >
      <FileKindIcon path={path} className="cv-chip__icon" />
      <span className="cv-chip__label">{label ?? pathName(path)}</span>
    </span>
  );
}

/// A web link: its text and `icon` (GitHub, arXiv) when given, both known before any lookup. The
/// hover card names the site, shows its favicon and title, and offers Open and Open in. The anchor
/// keeps the host's link-click path. `reference`: it draws as a reference chip (whole on one line,
/// its mark centred) though its address is no pull request's, as a nightly build's or a run's does.
export function UrlChip({
  href,
  icon,
  reference = false,
  children,
}: {
  href: string;
  icon?: ReactNode;
  reference?: boolean;
  children: ReactNode;
}) {
  const privateHost = isPrivateUrl(href);
  const known = useSiteInfo(href);
  // A dev server's or a device's page is never dressed as a site, whatever cmux browsed there.
  const site = privateHost ? undefined : known;
  // The link text is the address itself (a bare URL in a reply, or an autolink).
  const bare = typeof children === "string" && (children === href || /^[a-z][\w+.-]*:\/\//i.test(children));
  const label = bare ? redactUrlText(children as string) : children;
  // A pull request or issue is a reference chip (Leo 2026-10-19, as Claude desktop draws them): a
  // link with the GitHub mark and its text. Its title goes to the hover card only.
  const ref = githubRefLabel(href);
  const mark = ref ? <GitHubMark size={14} className="cv-chip__icon cv-chip__icon--gh" /> : icon;
  // The hover card always has an icon to show; a favicon cmux has fits there, not in the line.
  const favicon = site?.icon ? (
    <img className="cv-chip__icon cv-chip__favicon" src={site.icon} alt="" width={14} height={14} />
  ) : undefined;
  const cardMark = mark ?? favicon ?? <Globe size={16} className="cv-chip__icon" />;
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  // A pull request or an issue: both get the card and the state's colour (Leo 2026-11-08).
  const pullRequest = githubItemRef(href);
  // A pull request's mark takes its state's colour once the host knows it, as GitHub draws a
  // reference and as the card's glyph does: merged purple (Leo 2026-10-23, of a merged #23835's
  // blue chip: "I feel like this should be purple"). Colour only, so the chip never reflows.
  const state = usePullRequestState(pullRequest?.url);
  // An agent link (`cmux.com/deeplink/agent?...`) opens the reader's own session's chat
  // (conversation/SessionRef.tsx); its web page otherwise.
  const agent = useAgentLinkClick(href);
  // Once it names one of the reader's listed chats, its card is that chat's (started/SessionHoverCard.tsx),
  // opening it as the link does, in place of the site's.
  const subsessions = useContext(SubsessionContext);
  const session = useSessionHover(agent["data-open-session"] ?? "", subsessions?.openSender ?? subsessions?.open);
  // Its first hover or focus is what asks acpmux for the chat, so the answer can come in under the
  // site's card or its rest: the chat's card then takes over in place, in the same frame, with the
  // pointer or focus still on the link (review of #36360).
  const [entered, setEntered] = useState<"chat" | "site" | null>(null);
  const now = session.trigger.onPointerEnter !== undefined ? "chat" : "site";
  const chat = (entered ?? now) === "chat";
  const trigger = chat ? session.trigger : hover.trigger;
  const enter = () => {
    setEntered(now);
    return now === "chat" ? session.trigger : hover.trigger;
  };
  useLayoutEffect(() => {
    if (!anchor) return;
    if (entered === "chat" && now === "site") {
      // The chat left the list: the link is the site's again, and the site's card picks up a
      // pointer or focus still on it, with no leaving and coming back (review of #36360, F2).
      setEntered("site");
      if (anchor === document.activeElement) {
        hover.trigger.onFocus({ currentTarget: anchor } as unknown as FocusEvent<HTMLElement>);
      } else if (anchor.matches(":hover")) {
        const box = anchor.getBoundingClientRect();
        hover.trigger.onPointerEnter({
          currentTarget: anchor,
          clientX: (box.left + box.right) / 2,
          clientY: (box.top + box.bottom) / 2,
        } as unknown as PointerEvent<HTMLElement>);
      }
      return;
    }
    if (entered !== "site" || now !== "chat") return;
    setEntered("chat");
    const here = anchor.matches(":hover") || anchor === document.activeElement;
    if (!hover.open && !here) return;
    const shown = hover.open;
    hover.dismiss();
    session.takeOver(anchor, shown);
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- it runs when the link resolves, not per render.
  }, [entered, now, anchor]);
  return (
    <>
      <a
        ref={setAnchor}
        className={`cv-link cv-chip is-web${ref || reference ? " is-ref" : ""}`}
        data-pr-state={state}
        data-pr-kind={pullRequest?.kind === "issue" ? "issue" : undefined}
        data-session-ref={agent["data-session-ref"]}
        // A link to one of the reader's chats right-clicks as that chat (menuParts.ts `session`).
        data-open-session={agent["data-open-session"]}
        data-open-session-sender={agent["data-open-session-sender"]}
        href={href}
        rel="noreferrer"
        {...trigger}
        onPointerEnter={(event) => {
          agent.onPointerEnter?.();
          enter().onPointerEnter?.(event);
        }}
        onFocus={(event) => {
          agent.onFocus?.();
          enter().onFocus?.(event);
        }}
        onClick={agent.onClick}
      >
        {mark}
        <span className="cv-chip__label">{label}</span>
      </a>
      {chat ? (
        session.card
      ) : (
        <LinkHoverCard
          href={href}
          anchor={anchor}
          hover={hover}
          mark={cardMark}
          siteTitle={site?.title}
          pullRequest={
            pullRequest && {
              repo: pullRequest.repo,
              number: pullRequest.number,
              title: githubRefTitle(site?.title),
            }
          }
        />
      )}
    </>
  );
}

/// A file id only its provider opens (`foreignFileIds`): its id, shortened, and a note that it
/// cannot be opened here. Never a link, a file chip or an image (Leo, 2026-11-06: "do we not have
/// a good path for them sending images to you?"); an agent hands over an image with
/// `acpmux send --attach`.
export function ForeignFileRef({ id }: { id: string }) {
  const t = useT();
  const shown = id.length > 20 ? `${id.slice(0, 16)}…` : id;
  return (
    <span className="cv-foreign-file">
      <Lock size={12} className="cv-foreign-file__icon" />
      <span className="cv-foreign-file__id">{shown}</span>
      <span className="cv-foreign-file__note">{t("message.foreignFile")}</span>
    </span>
  );
}
