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
import { useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { callChipHost } from "./host";
import { useMessageScope } from "./messageScope";
import { Folder, GitHubMark, Globe } from "../conversation/icons";
import { FileKindIcon } from "./FileKindIcon";
import { usePathInfo, useSiteInfo } from "./linkStore";
import { isPrivateUrl, redactUrlText } from "./linkDisplay";
import { isDeniedPath, pathName, textLinks } from "./paths";
import { bareFileNames, useReplyFolders } from "./replyFolders";
import { LinkHoverCard } from "./LinkHoverCard";
import { pullRequestRef } from "./PullRequestCard";
import { usePullRequestState } from "./pullRequestStore";
import { useHoverCard } from "./useHoverCard";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { useAgentLinkClick } from "../conversation/SessionRef";

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
/// keeps the host's link-click path.
export function UrlChip({ href, icon, children }: { href: string; icon?: ReactNode; children: ReactNode }) {
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
  const pullRequest = pullRequestRef(href);
  // A pull request's mark takes its state's colour once the host knows it, as GitHub draws a
  // reference and as the card's glyph does: merged purple (Leo 2026-10-23, of a merged #23835's
  // blue chip: "I feel like this should be purple"). Colour only, so the chip never reflows.
  const state = usePullRequestState(pullRequest?.url);
  // An agent link (`cmux.com/deeplink/agent?...`) opens the reader's own session's chat
  // (conversation/SessionRef.tsx); its web page otherwise.
  const agent = useAgentLinkClick(href);
  return (
    <>
      <a
        ref={setAnchor}
        className={`cv-link cv-chip is-web${ref ? " is-ref" : ""}`}
        data-pr-state={state}
        data-session-ref={agent["data-session-ref"]}
        // A link to one of the reader's chats right-clicks as that chat (menuParts.ts `session`).
        data-open-session={agent["data-open-session"]}
        data-open-session-sender={agent["data-open-session-sender"]}
        href={href}
        rel="noreferrer"
        {...hover.trigger}
        onPointerEnter={(event) => {
          agent.onPointerEnter?.();
          hover.trigger.onPointerEnter(event);
        }}
        onFocus={(event) => {
          agent.onFocus?.();
          hover.trigger.onFocus(event);
        }}
        onClick={agent.onClick}
      >
        {mark}
        <span className="cv-chip__label">{label}</span>
      </a>
      <LinkHoverCard
        href={href}
        anchor={anchor}
        hover={hover}
        mark={cardMark}
        siteTitle={site?.title}
        pullRequest={pullRequest && { ...pullRequest, title: githubRefTitle(site?.title) }}
      />
    </>
  );
}

/// Plain reply text with its paths and URLs as chips (D4); `key` prefixes the chips' keys.
export function linkedText(text: string, key: string): ReactNode[] {
  const links = textLinks(text);
  if (!links.length) return namedText(text, key);
  const out: ReactNode[] = [];
  let at = 0;
  links.forEach((link, index) => {
    if (link.start > at) out.push(...namedText(text.slice(at, link.start), `${key}-${index}-names`));
    out.push(
      link.kind === "path" ? (
        <PathChip
          key={`${key}-${index}`}
          path={link.path!}
          written={link.value}
          label={link.line ? `${pathName(link.path!)}:${link.line}` : undefined}
        />
      ) : (
        <UrlChip key={`${key}-${index}`} href={link.value}>
          {githubRefLabel(link.value) ?? link.value}
        </UrlChip>
      ),
    );
    at = link.end;
  });
  if (at < text.length) out.push(...namedText(text.slice(at), `${key}-names`));
  return out;
}

/// Text between a reply's paths: each bare file name may be a file in a folder the reply names.
function namedText(text: string, key: string): ReactNode[] {
  const names = bareFileNames(text);
  if (!names.length) return [text];
  const out: ReactNode[] = [];
  let at = 0;
  names.forEach((name, index) => {
    if (name.start > at) out.push(text.slice(at, name.start));
    out.push(<SiblingFileChip key={`${key}-${index}`} name={name.name} />);
    at = name.end;
  });
  if (at < text.length) out.push(text.slice(at));
  return out;
}

const GITHUB_REF = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/(?:pull|issues)\/(\d+)\/?(?:[?#].*)?$/;

/// `owner/repo#N` for a GitHub pull request or issue address, else undefined.
export function githubRefLabel(href: string): string | undefined {
  const match = GITHUB_REF.exec(href);
  return match ? `${match[1]}#${match[2]}` : undefined;
}

/// A pull request's or issue's own title from GitHub's page title ("Fix the thing by leo ·
/// Pull Request #12 · owner/repo · GitHub") for its hover card, or undefined when cmux has no
/// title for it.
export function githubRefTitle(page: string | undefined): string | undefined {
  if (!page) return undefined;
  const title = page
    .split(" · ")[0]!
    .replace(/ by [\w-]+$/, "")
    .trim();
  return title && !/^(GitHub|Pull Request|Issue)\b/.test(title) ? title : undefined;
}
