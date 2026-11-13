// A web search or fetch call's sources (webSourceList.ts) under its row. A search draws one quiet
// line, "Sources" and the first sites, each with its icon, that opens to a compact list of the pages
// it read: icon, title and site per row. A fetch draws the one page it read as a link card: icon,
// the page's title (or where it sits on its site) and the site. A click on a page opens it in a cmux
// browser tab, as a link in a reply does (chips/LinkHoverCard.tsx `browser.openIn`). In a read-only
// transcript (readOnly.ts) cmux's tabs are the owner's: a page opens in the reader's browser.
//
// A site's icon is the one cmux already has from its own browser (chips/linkStore.ts `link.inspect`;
// the host never fetches for it). Until it answers, or when it has none, the globe holds the same
// 14px slot, so an icon arriving never moves a word.
import { memo, useId, useState, type MouseEvent, type ReactNode } from "react";
import { callChipHost } from "../chips/host";
import { useSiteInfo } from "../chips/linkStore";
import { useT } from "../i18n";
import { useTranscriptReadOnly } from "./readOnly";
import { ChevronRight, Globe } from "./icons";
import { pagePathLabel, sourcesLine, type WebSource } from "./webSourceList";
import "./WebSources.css";
import { Sign } from "../../../ui/Typography";

/// The sites the closed line names before "+N", the pages from any other site.
const NAMED = 3;

const open = (url: string) => void callChipHost("browser.openIn", { url, browserId: "cmux" }).catch(() => undefined);

/// The page's site icon in a fixed 14px slot: cmux's favicon when it has one, else the globe.
function SiteMark({ url }: { url: string }) {
  const icon = useSiteInfo(url)?.icon;
  const [broken, setBroken] = useState<string | undefined>(undefined);
  return (
    <span className="cv-web-sources__icon" aria-hidden="true">
      {icon && broken !== icon ? (
        <img src={icon} alt="" width={14} height={14} draggable={false} onError={() => setBroken(icon)} />
      ) : (
        <Globe size={12} />
      )}
    </span>
  );
}

/// An anchor that opens its page in a cmux tab, or, read only, in the reader's browser.
function PageLink({ url, className, children }: { url: string; className: string; children: ReactNode }) {
  const readOnly = useTranscriptReadOnly();
  return (
    <a
      href={url}
      className={className}
      title={url}
      {...(readOnly
        ? { target: "_blank", rel: "noopener noreferrer" }
        : {
            onClick: (event: MouseEvent<HTMLAnchorElement>) => {
              event.preventDefault();
              open(url);
            },
          })}
    >
      {children}
    </a>
  );
}

/// A fetch's one page: icon, title, site. The title is the one cmux has for the page, else where the
/// page sits on its site ("claude-code/hooks"), else the site alone.
const WebPageCard = memo(function WebPageCard({ page }: { page: WebSource }) {
  const known = useSiteInfo(page.url)?.title?.trim();
  const title = known || pagePathLabel(page.url);
  return (
    <div className="cv-web-sources">
      <PageLink url={page.url} className="cv-web-sources__chip cv-web-sources__card">
        <SiteMark url={page.url} />
        {title && <span className="cv-web-sources__title">{title}</span>}
        <span className={title ? "cv-web-sources__site" : "cv-web-sources__title"}>{page.host}</span>
      </PageLink>
    </div>
  );
});

export const WebSources = memo(function WebSources({
  sources,
  fetched,
}: {
  sources: readonly WebSource[];
  /// The call read one page (a fetch): draw it as a link card, not a sources list.
  fetched?: WebSource;
}) {
  const t = useT();
  const [shown, setShown] = useState(false);
  const listId = useId();
  if (fetched) return <WebPageCard page={fetched} />;
  if (!sources.length) return null;
  const { named, more } = sourcesLine(sources, NAMED);
  return (
    <div className="cv-web-sources">
      <button
        type="button"
        className="cv-web-sources__chip"
        aria-expanded={shown}
        aria-controls={shown ? listId : undefined}
        onClick={() => setShown((value) => !value)}
      >
        <span className="cv-web-sources__label">{t("tools.webSources")}</span>
        <span className="cv-web-sources__hosts">
          {named.map((host) => (
            <span key={host} className="cv-web-sources__named">
              <SiteMark url={sources.find((source) => source.host === host)!.url} />
              <span className="cv-web-sources__host">{host}</span>
            </span>
          ))}
        </span>
        {more > 0 && (
          <span className="cv-web-sources__more">
            <Sign />
            {more}
          </span>
        )}
        <ChevronRight size={12} className={`cv-rotor${shown ? " is-open" : ""}`} />
      </button>
      {shown && (
        <ul id={listId} className="cv-web-sources__list">
          {sources.map((source) => (
            <li key={source.url}>
              <PageLink url={source.url} className="cv-web-sources__page">
                <SiteMark url={source.url} />
                <span className="cv-web-sources__title">{source.title}</span>
                <span className="cv-web-sources__site">{source.host}</span>
              </PageLink>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
});
