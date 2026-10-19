// Link and path chips in replies (decision D4): an icon, the name with a dotted underline, and
// the full address in the tooltip. A path chip asks the host where its path is (`link.inspect`)
// and opens through the host (`link.openPath`, or `link.readPath` into the chat's viewer with
// labs `chatViewer`: the deny list and the session's folders after
// symlinks, then a user gesture; outside the folders, `agentPane.links.outsideRoots` decides and
// the host's own sheet asks). A web chip is an ordinary link, which the host opens outside the
// pane after a real click; its icon is the site's favicon when cmux already has one.
import { useEffect, useRef, useState, type PointerEvent, type ReactNode } from "react";
import { callChipHost, openPathChip } from "./host";
import { FileDoc, Folder, Globe, Lock } from "../conversation/icons";
import { usePathInfo, useSiteInfo } from "./linkStore";
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
      onClick={() => openPathChip(path)}
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
  const mark = site?.icon ? (
    <img className="cv-chip__icon cv-chip__favicon" src={site.icon} alt="" width={14} height={14} />
  ) : (
    (icon ?? <Globe size={15} strokeWidth={1.1} className="cv-chip__icon" />)
  );
  const [cardOpen, setCardOpen] = useState(false);
  const cardHoverRef = useRef(false);
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
      if (!cardHoverRef.current) setCardOpen(false);
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
        className="cv-link cv-chip is-web"
        href={href}
        rel="noreferrer"
        onPointerEnter={onPointerEnter}
        onPointerLeave={onPointerLeave}
        onFocus={onFocus}
        onBlur={onBlur}
      >
        {mark}
        <span className="cv-chip__label">{children}</span>
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
          onFocusCapture={() => {
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
            <span className="cv-link-preview__icon">{mark}</span>
            <span className="cv-link-preview__site">{site?.title ?? host}</span>
            <button type="button" className="cv-link-preview__open" onClick={onOpen}>
              {t("image.open")}
              <span aria-hidden="true">↗</span>
            </button>
          </div>
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
          {link.value}
        </UrlChip>
      ),
    );
    at = link.end;
  });
  if (at < text.length) out.push(text.slice(at));
  return out;
}
