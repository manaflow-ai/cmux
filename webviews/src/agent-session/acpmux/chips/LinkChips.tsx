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
import { FileDoc, Folder, GitHubMark, Globe } from "../conversation/icons";
import { usePathInfo, useSiteInfo } from "./linkStore";
import { isPrivateUrl, redactUrlText } from "./linkDisplay";
import { isDeniedPath, isNameOnlyPath, pathName, textLinks } from "./paths";
import { LinkHoverCard } from "./LinkHoverCard";
import { pullRequestRef } from "./PullRequestCard";
import { useHoverCard } from "./useHoverCard";
import { locationArgument, type FileLocation } from "../../../fileLocation";

/// A path chip. `label` is the link's text, else the file name; `written` is the reply's own
/// text, which a path that gets no chip draws as.
type PathChipProps = {
  path: string;
  label?: ReactNode;
  written?: string;
  location?: FileLocation;
  suffix?: string;
  /// Written in a code span: a path that gets no chip stays code.
  code?: boolean;
  /// A bare file name: no chip until the host has found the file.
  bare?: boolean;
};

/// What a path that gets no chip draws as: code for a code span, else the reply's text.
function NoChip({ path, label, written, code }: PathChipProps) {
  const text = written ?? label ?? path;
  return code ? <code className="cv-code">{text}</code> : <span className="cv-chip-plain">{text}</span>;
}

export function PathChip({ path, label, written, ...position }: PathChipProps) {
  const scope = useMessageScope();
  if (isDeniedPath(path)) return <NoChip path={path} label={label} written={written} code={position.code} />;
  // Another machine's file: never asked about or opened here (chips/messageScope.ts).
  if (scope?.host !== undefined)
    return <ElsewhereChip path={path} host={scope.host} label={label} suffix={position.suffix} />;
  return <HostPathChip path={path} label={label} written={written} {...position} />;
}

function HostPathChip({ path, label, written, location, suffix, code, bare }: PathChipProps) {
  const t = useT();
  // A name with no folder is a chip only once the host has found that file.
  const nameOnly = bare || isNameOnlyPath(path);
  const { info, policy } = usePathInfo(path, nameOnly);
  const plain =
    info?.place === "denied" ||
    info?.place === "missing" ||
    (info?.place === "outside" && policy.outsideRoots === "text") ||
    // A name with no folder is no chip until the host has answered (then it follows the same
    // rules as any path: outside the folders it is marked, or opens, by the policy).
    (nameOnly && !info);
  if (plain) return <NoChip path={path} label={label} written={written} code={code} />;
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
      data-line={!folder && location ? locationArgument(location) : undefined}
      onClick={() =>
        void callChipHost("link.openPath", {
          path,
          ...(!folder && location ? { line: locationArgument(location) } : {}),
        })
      }
    >
      {folder ? <Folder size={15} className="cv-chip__icon" /> : <FileDoc size={15} className="cv-chip__icon" />}
      <span className="cv-chip__label">
        {label ?? pathName(path)}
        {folder ? "" : suffix}
      </span>
    </button>
  );
}

interface ElsewhereChipProps {
  path: string;
  host: string;
  label?: ReactNode;
  /** The written `:line` (or `#L…`), kept in the label as on this Mac's chips. */
  suffix?: string;
}

/// A file on the machine an agent's message came from: its name, the path and the
/// machine in its tooltip. Not a button: this Mac has no way to it.
export function ElsewhereChip({ path, host, label, suffix }: ElsewhereChipProps) {
  const t = useT();
  const where = host ? t("message.fileOnHost", { host, path }) : t("message.fileElsewhere", { path });
  return (
    <span
      className="cv-chip is-path is-elsewhere"
      data-path={path}
      /* tooltip-allow: the chip shows the file's name only; the tooltip says where it is */ title={where}
      aria-label={where}
    >
      <FileDoc size={15} className="cv-chip__icon" />
      <span className="cv-chip__label">
        {label ?? pathName(path)}
        {path.endsWith("/") ? "" : suffix}
      </span>
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
  const mark = ref ? <GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" /> : icon;
  // The hover card always has an icon to show; a favicon cmux has fits there, not in the line.
  const favicon = site?.icon ? (
    <img className="cv-chip__icon cv-chip__favicon" src={site.icon} alt="" width={14} height={14} />
  ) : undefined;
  const cardMark = mark ?? favicon ?? <Globe size={15} strokeWidth={1.1} className="cv-chip__icon" />;
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  const pullRequest = pullRequestRef(href);
  return (
    <>
      <a
        ref={setAnchor}
        className={`cv-link cv-chip is-web${ref ? " is-ref" : ""}`}
        href={href}
        rel="noreferrer"
        {...hover.trigger}
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
  if (!links.length) return [text];
  const out: ReactNode[] = [];
  let at = 0;
  links.forEach((link, index) => {
    if (link.start > at) out.push(text.slice(at, link.start));
    out.push(
      link.kind === "path" ? (
        <PathChip
          key={`${key}-${index}`}
          path={link.path!}
          written={link.value}
          location={link.location}
          suffix={link.suffix}
        />
      ) : (
        <UrlChip key={`${key}-${index}`} href={link.value}>
          {githubRefLabel(link.value) ?? link.value}
        </UrlChip>
      ),
    );
    at = link.end;
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
