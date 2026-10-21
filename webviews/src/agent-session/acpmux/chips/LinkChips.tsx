// Link and path chips in replies (decision D4): an icon, the name with a dotted underline, and
// the full address in the tooltip. A path chip asks the host where its path is (`link.inspect`)
// and opens through the host (`link.openPath`: the deny list and the session's folders after
// symlinks, then a user gesture; outside the folders, `agentPane.links.outsideRoots` decides and
// the host's own sheet asks). A web chip is an ordinary link, which the host opens outside the
// pane after a real click; its icon is the site's favicon when cmux already has one.
import { useRef, type PointerEvent, type ReactNode } from "react";
import { callChipHost } from "./host";
import { FileDoc, Folder, GitHubMark, Globe, Lock } from "../conversation/icons";
import { usePathInfo, useSiteInfo } from "./linkStore";
import { isDeniedPath, pathName, textLinks } from "./paths";
import { AnchoredCard } from "../../../ui/Tooltip";
import { PullRequestCardBody, pullRequestRef } from "./PullRequestCard";
import { useHoverCard } from "./useHoverCard";
import { useT } from "../i18n";

/// A path chip. `label` is the link's text, else the file name; `written` is the reply's own
/// text, which a path that gets no chip draws as.
export function PathChip({ path, label, written }: { path: string; label?: ReactNode; written?: string }) {
  if (isDeniedPath(path)) return <span className="cv-chip-plain">{written ?? label ?? path}</span>;
  return <HostPathChip path={path} label={label} written={written} />;
}

function HostPathChip({ path, label, written }: { path: string; label?: ReactNode; written?: string }) {
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
      onClick={() => void callChipHost("link.openPath", { path })}
    >
      {folder ? <Folder size={15} className="cv-chip__icon" /> : <FileDoc size={15} className="cv-chip__icon" />}
      <span className="cv-chip__label">{label ?? pathName(path)}</span>
      {outside && <Lock size={11} className="cv-chip__lock" />}
    </button>
  );
}

/// A web chip: the site's favicon when cmux has one, else `icon` (GitHub, arXiv) or a globe; the
/// link text; the full URL in the tooltip. The anchor keeps the host's link-click path.
export function UrlChip({ href, icon, children }: { href: string; icon?: ReactNode; children: ReactNode }) {
  const t = useT();
  const site = useSiteInfo(href);
  // A pull request or issue is a reference chip (Leo 2026-10-19, as Claude desktop draws them): a
  // pill with the GitHub mark, `owner/repo#N`, and the title cmux already has for it.
  const ref = githubRefLabel(href);
  const refTitle = ref ? githubRefTitle(site?.title) : undefined;
  const mark = ref ? (
    <GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" />
  ) : site?.icon ? (
    <img className="cv-chip__icon cv-chip__favicon" src={site.icon} alt="" width={14} height={14} />
  ) : (
    (icon ?? <Globe size={15} strokeWidth={1.1} className="cv-chip__icon" />)
  );
  // A pull request's card also shows its full title, state, author and checks (PullRequestCard.tsx).
  const pullRequest = pullRequestRef(href);
  const hover = useHoverCard();
  const cardOpen = hover.open;
  const anchor = useRef<HTMLAnchorElement | null>(null);
  const onOpen = (event: PointerEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    void callChipHost("browser.open", { url: href });
  };
  const host = (() => {
    try {
      return new URL(href).host;
    } catch {
      return href;
    }
  })();
  return (
    <>
      <a
        ref={anchor}
        className={`cv-link cv-chip is-web${ref ? " is-ref" : ""}`}
        href={href}
        rel="noreferrer"
        {...hover.trigger}
      >
        {mark}
        <span className="cv-chip__label">{children}</span>
        {refTitle && <span className="cv-chip__title">{refTitle}</span>}
      </a>
      <AnchoredCard
        anchor={cardOpen ? anchor.current : null}
        className={pullRequest ? "cv-link-preview acpmux-pr-card" : "cv-link-preview"}
        interactive
        ariaLabel={site?.title ?? host}
      >
        <div {...hover.card}>
          <div className="cv-link-preview__head">
            <span className="cv-link-preview__icon">{mark}</span>
            <span className="cv-link-preview__site">{site?.title ?? host}</span>
            <button type="button" className="cv-link-preview__open" onClick={onOpen}>
              {t("image.open")}
              <span aria-hidden="true">↗</span>
            </button>
          </div>
          {pullRequest && (
            <PullRequestCardBody url={href} known={{ ...pullRequest, title: refTitle }} open={cardOpen} />
          )}
          <div className="cv-link-preview__target">
            {host} · {href}
          </div>
        </div>
      </AnchoredCard>
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
        <PathChip key={`${key}-${index}`} path={link.path!} written={link.value} />
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
/// Pull Request #12 · owner/repo · GitHub"), or undefined when cmux has no title for it.
export function githubRefTitle(page: string | undefined): string | undefined {
  if (!page) return undefined;
  const title = page
    .split(" · ")[0]!
    .replace(/ by [\w-]+$/, "")
    .trim();
  return title && !/^(GitHub|Pull Request|Issue)\b/.test(title) ? title : undefined;
}
