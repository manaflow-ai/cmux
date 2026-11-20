import { useId, useState } from "react";
import { useT } from "../i18n";
import { sourceFilePath, type MessageSource } from "../messageSources";
import { safeHref } from "../replyHref";
import { FileButton } from "./FileResultCard";
import { PageLink } from "./WebSources";
import { ChevronRight } from "./icons";
import "./MessageSources.css";

/** The reply's actual read provenance, disclosed only when the person asks for it. */
export function MessageSources({ sources }: { sources?: readonly MessageSource[] }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const id = useId();
  if (!sources?.length) return null;
  return (
    <div className="cv-message-sources cv-web-sources">
      <button
        type="button"
        className="cv-web-sources__chip"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((shown) => !shown)}
      >
        <span className="cv-web-sources__label">{t("tools.webSources")}</span>
        <span>{sources.length}</span>
        <ChevronRight size={12} className={`cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {open && (
        <div id={id}>
          <p className="cv-message-sources__caption">{t("turn.sources.readDuring")}</p>
          <ul className="cv-web-sources__list">
            {sources.map((source) => {
              const href = safeHref(source.uri);
              const path = sourceFilePath(source.uri);
              const title = <span className="cv-web-sources__title">{source.title || source.uri}</span>;
              return (
                <li key={`${source.uri}:${source.revision ?? ""}`} data-source-tool={source.toolCallId}>
                  {href ? (
                    <PageLink url={href} className="cv-web-sources__page">
                      {title}
                    </PageLink>
                  ) : path ? (
                    <FileButton path={path} className="cv-web-sources__page" label={source.uri}>
                      {title}
                    </FileButton>
                  ) : (
                    <span className="cv-web-sources__page">{title}</span>
                  )}
                  {source.revision && <span className="cv-web-sources__site">{source.revision}</span>}
                  {source.backlink && (
                    <PageLink url={source.backlink} className="cv-web-sources__page">
                      {t("turn.sources.backlinks")}
                    </PageLink>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      )}
    </div>
  );
}
