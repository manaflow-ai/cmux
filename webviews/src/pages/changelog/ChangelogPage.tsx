// The changelog page (`cmux-page://cmux.changelog/`, R114): the build list on the left, the
// selected build's human highlights (with an allow-listed "Try it") and its full change list on
// the right. A plain white document: the page has no backdrop of its own.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import type { ChangelogStore } from "./store";
import type { Highlight } from "./types";

export function ChangelogPage({ store, strings }: { store: ChangelogStore; strings: Strings }) {
  const s = useSyncExternalStore(store.subscribe, store.getSnapshot);
  if (s.loading) return <div className="cl-empty">{strings.t("changelog.page.loading")}</div>;
  return (
    <div className="cl">
      <nav className="cl-list" aria-label={strings.t("changelog.page.versions")}>
        {s.builds.length === 0 && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
        {s.builds.map((b) => (
          <button
            key={b.build}
            type="button"
            className={`cl-version${b.build === s.selected ? " is-selected" : ""}`}
            aria-current={b.build === s.selected ? "true" : undefined}
            onClick={() => void store.select(b.build)}
          >
            <span className="cl-version-name">{b.shortVersion}</span>
            <span className="cl-version-date">{b.date}</span>
            {b.highlights > 0 && <span className="cl-dot" aria-label={strings.t("changelog.page.hasHighlights")} />}
            {b.build === s.current && <span className="cl-current">{strings.t("changelog.page.current")}</span>}
          </button>
        ))}
      </nav>
      <article className="cl-notes">
        {s.failed && <p className="cl-error">{s.failed}</p>}
        {s.missing && <p className="cl-muted">{strings.t("changelog.page.unavailable")}</p>}
        {s.notes && (
          <>
            <header>
              <h1>{strings.format("changelog.page.heading", s.notes.shortVersion)}</h1>
              <p className="cl-muted">{s.notes.date}</p>
            </header>
            {s.notes.highlights.map((h) => (
              <HighlightView key={h.id} highlight={h} onTry={(id) => void store.tryIt(id)} />
            ))}
            {s.notes.changes.length > 0 && (
              <section className="cl-changes">
                <h2>{strings.t("changelog.page.allChanges")}</h2>
                <ul>
                  {s.notes.changes.map((c, i) => (
                    <li key={i}>{c}</li>
                  ))}
                </ul>
              </section>
            )}
          </>
        )}
      </article>
    </div>
  );
}

function HighlightView({ highlight, onTry }: { highlight: Highlight; onTry: (action: string) => void }) {
  return (
    <section className="cl-highlight">
      <h2>{highlight.title}</h2>
      {highlight.body.split(/\n{2,}/).map((p, i) => (
        <p key={i}>{p}</p>
      ))}
      {highlight.action && (
        <button type="button" className="cl-try" onClick={() => onTry(highlight.action!.id)}>
          {highlight.action.title}
        </button>
      )}
    </section>
  );
}
