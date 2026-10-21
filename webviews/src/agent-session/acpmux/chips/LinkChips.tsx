// Link and path chips in replies (decision D4): an icon, the name with a dotted underline, and
// the full address in the tooltip. A path chip asks the host where its path is (`link.inspect`)
// and opens through the host (`link.openPath`: the deny list and the session's folders after
// symlinks, then a user gesture; outside the folders, `agentPane.links.outsideRoots` decides and
// the host's own sheet asks). A web chip is an ordinary link, which the host opens outside the
// pane after a real click. It reads as plain link text (Claude Code desktop's links): the site's
// favicon only beside a title cmux already has, a local or private address never dressed as a
// site, and a secret-looking query value as `•••` (linkDisplay.ts). Hovering it offers Open and
// Open in.
import { useEffect, useRef, useState, type PointerEvent, type ReactNode } from "react";
import { callChipHost } from "./host";
import { FileDoc, Folder, GitHubMark, Globe, Lock } from "../conversation/icons";
import { usePathInfo, useSiteInfo } from "./linkStore";
import { isPrivateUrl, redactUrlText } from "./linkDisplay";
import { OpenInMenu } from "../previewCard/OpenInMenu";
import { isDeniedPath, pathName, textLinks } from "./paths";
import { HOVER_INTENT } from "../../../ui/hoverIntent";
import { AnchoredCard } from "../../../ui/Tooltip";
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

/// A web link: its text, `icon` (GitHub, arXiv) when given, and the site's favicon only when cmux
/// has the site's title too (a bare address then reads as that title). The hover card names the
/// site and the address and offers Open and Open in. The anchor keeps the host's link-click path.
export function UrlChip({ href, icon, children }: { href: string; icon?: ReactNode; children: ReactNode }) {
  const t = useT();
  const privateHost = isPrivateUrl(href);
  const known = useSiteInfo(href);
  // A dev server's or a device's page is never dressed as a site, whatever cmux browsed there.
  const site = privateHost ? undefined : known;
  // The link text is the address itself (a bare URL in a reply, or an autolink).
  const bare = typeof children === "string" && (children === href || /^[a-z][\w+.-]*:\/\//i.test(children));
  const shown = bare ? redactUrlText(children as string) : children;
  const shownHref = redactUrlText(href);
  // A pull request or issue is a reference chip (Leo 2026-10-19, as Claude desktop draws them): a
  // pill with the GitHub mark, `owner/repo#N`, and the title cmux already has for it.
  const ref = githubRefLabel(href);
  const refTitle = ref ? githubRefTitle(site?.title) : undefined;
  const titled = !ref && Boolean(site?.title);
  const favicon = site?.icon ? (
    <img className="cv-chip__icon cv-chip__favicon" src={site.icon} alt="" width={14} height={14} />
  ) : undefined;
  const mark = ref ? (
    <GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" />
  ) : titled && favicon ? (
    favicon
  ) : (
    icon
  );
  // The hover card always has an icon to show.
  const cardMark = mark ?? favicon ?? <Globe size={15} strokeWidth={1.1} className="cv-chip__icon" />;
  const label = titled && bare ? site!.title : shown;
  const [cardOpen, setCardOpen] = useState(false);
  const cardHoverRef = useRef(false);
  /// The card's Open in menu is open: the card stays until it closes.
  const menuOpenRef = useRef(false);
  const anchor = useRef<HTMLAnchorElement | null>(null);
  const openTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const clearTimers = () => {
    if (openTimer.current !== undefined) clearTimeout(openTimer.current);
    if (closeTimer.current !== undefined) clearTimeout(closeTimer.current);
    openTimer.current = undefined;
    closeTimer.current = undefined;
  };
  const showCard = (immediate = false) => {
    clearTimers();
    if (immediate) setCardOpen(true);
    else openTimer.current = setTimeout(() => setCardOpen(true), HOVER_INTENT.cardDwell);
  };
  const hideCard = () => {
    clearTimers();
    closeTimer.current = setTimeout(() => {
      if (!cardHoverRef.current && !menuOpenRef.current) setCardOpen(false);
    }, HOVER_INTENT.cardGrace);
  };
  useEffect(() => () => clearTimers(), []);
  const onPointerEnter = () => showCard();
  const onPointerLeave = () => hideCard();
  const onFocus = () => showCard(true);
  const onBlur = () => hideCard();
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
        className={`cv-link cv-chip is-web${ref ? " is-ref" : ""}${titled ? " is-titled" : ""}`}
        href={href}
        rel="noreferrer"
        onPointerEnter={onPointerEnter}
        onPointerLeave={onPointerLeave}
        onFocus={onFocus}
        onBlur={onBlur}
      >
        {mark}
        <span className="cv-chip__label">{label}</span>
        {refTitle && <span className="cv-chip__title">{refTitle}</span>}
      </a>
      <AnchoredCard
        anchor={cardOpen ? anchor.current : null}
        className="cv-link-preview"
        interactive
        ariaLabel={site?.title ?? host}
      >
        <div
          onPointerEnter={() => {
            clearTimers();
            cardHoverRef.current = true;
          }}
          onPointerLeave={() => {
            cardHoverRef.current = false;
            hideCard();
          }}
          onFocusCapture={(event) => {
            // Keyboard focus keeps the card. A pointer pick in Open in puts focus back on its trigger
            // with no ring (Menu's focusAfterClose); that alone doesn't pin the card once the pointer
            // has left it.
            if (!(event.target as Element).matches(":focus-visible") && !event.currentTarget.matches(":hover")) return;
            clearTimers();
            cardHoverRef.current = true;
            setCardOpen(true);
          }}
          onBlurCapture={() => {
            cardHoverRef.current = false;
            hideCard();
          }}
        >
          <div className="cv-link-preview__head">
            <span className="cv-link-preview__icon">{cardMark}</span>
            <span className="cv-link-preview__site">{site?.title ?? host}</span>
            <button type="button" className="cv-link-preview__open" onClick={onOpen}>
              {t("image.open")}
              <span aria-hidden="true">↗</span>
            </button>
            <OpenInMenu
              url={href}
              onOpenInPane={(url) => void callChipHost("browser.open", { url })}
              onOpenChange={(open) => {
                menuOpenRef.current = open;
                if (open) clearTimers();
                else hideCard();
              }}
            />
          </div>
          <div className="cv-link-preview__target">
            {host} · {shownHref}
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
