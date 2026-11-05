// A web search or fetch call's sources (webSources.ts) under its row: one quiet line, "Sources"
// and the first sites' names, that opens to each page's title and site; a click on a page opens
// it in a cmux browser tab, as a link in a reply does (chips/LinkHoverCard.tsx `browser.openIn`).
import { memo, useId, useState } from "react";
import { callChipHost } from "../chips/host";
import { useT } from "../i18n";
import { ChevronRight, Globe } from "./icons";
import type { WebSource } from "./webSources";
import "./WebSources.css";

/// The sites the closed line names before "+N".
const NAMED = 3;

const open = (url: string) => void callChipHost("browser.openIn", { url, browserId: "cmux" }).catch(() => undefined);

export const WebSources = memo(function WebSources({ sources }: { sources: readonly WebSource[] }) {
  const t = useT();
  const [shown, setShown] = useState(false);
  const listId = useId();
  if (!sources.length) return null;
  const hosts = [...new Set(sources.map((source) => source.host))];
  const more = hosts.length - NAMED;
  return (
    <div className="cv-web-sources">
      <button
        type="button"
        className="cv-web-sources__chip"
        aria-expanded={shown}
        aria-controls={shown ? listId : undefined}
        onClick={() => setShown((value) => !value)}
      >
        <Globe size={12} />
        <span className="cv-web-sources__label">{t("tools.webSources")}</span>
        <span className="cv-web-sources__hosts">{hosts.slice(0, NAMED).join(" · ")}</span>
        {more > 0 && <span className="cv-web-sources__more">+{more}</span>}
        <ChevronRight size={12} className={`cv-rotor${shown ? " is-open" : ""}`} />
      </button>
      {shown && (
        <ul id={listId} className="cv-web-sources__list">
          {sources.map((source) => (
            <li key={source.url}>
              <a
                href={source.url}
                className="cv-web-sources__page"
                title={source.url}
                onClick={(event) => {
                  event.preventDefault();
                  open(source.url);
                }}
              >
                <span className="cv-web-sources__title">{source.title}</span>
                <span className="cv-web-sources__site">{source.host}</span>
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
});
