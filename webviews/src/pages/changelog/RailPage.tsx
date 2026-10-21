// Design B, Rail + reader (cx-urd.61; Debug Settings `whatsNew.design = rail`, kept until the
// journal has been dogfooded): a narrow date rail (an update's releases marked with a dot) and
// the selected release on the right.
import type { Strings } from "../shared/i18n";
import { formatReleaseDate, releaseView } from "./model";
import { ChangesFold, Groups, Hero, ReleaseMeta, type PartsContext } from "./ReleaseParts";
import type { ChangelogSnapshot, ChangelogStore } from "./store";

export function RailPage({ store, strings, s }: { store: ChangelogStore; strings: Strings; s: ChangelogSnapshot }) {
  const ctx: PartsContext = { strings, onTry: (id) => void store.tryIt(id) };
  const view = s.notes ? releaseView(s.notes, strings.language) : undefined;
  return (
    <div className="clr">
      <nav className="clr-rail" aria-label={strings.t("changelog.page.versions")}>
        {s.inSpan.length > 0 && <div className="clr-rail-head">{strings.t("changelog.page.sinceLastUpdate")}</div>}
        {s.builds.length === 0 && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
        {s.builds.map((b) => (
          <button
            key={b.build}
            type="button"
            className={`clr-version${b.build === s.selected ? " is-selected" : ""}${s.inSpan.includes(b.build) ? " in-span" : ""}`}
            aria-current={b.build === s.selected ? "true" : undefined}
            onClick={() => void store.select(b.build)}
          >
            <span className="clr-date">{formatReleaseDate(b.date, strings.language)}</span>
            {s.inSpan.includes(b.build) && (
              <span className="clr-dot" aria-label={strings.t("changelog.page.sinceLastUpdate")} />
            )}
            <span className="clr-version-name">{b.shortVersion}</span>
          </button>
        ))}
      </nav>
      <article className="clr-reader">
        {s.failed && <p className="cl-error">{s.failed}</p>}
        {s.span && (s.inSpan.length === 0 || (s.missing && !!s.selected && s.inSpan.includes(s.selected))) && (
          <h1 className="cl-updated" data-testid="changelog.updatedTo">
            {strings.format("changelog.page.updatedTo", s.span.to)}
          </h1>
        )}
        {s.missing && <p className="cl-muted">{strings.t("changelog.page.unavailable")}</p>}
        {s.notes && view && (
          <>
            <ReleaseMeta date={s.notes.date} version={s.notes.shortVersion} strings={strings} />
            {view.hero ? (
              <Hero item={view.hero} ctx={ctx} level={1} />
            ) : (
              <h1 className="cl-headline">{strings.format("changelog.page.heading", s.notes.shortVersion)}</h1>
            )}
            <div className="clr-groups">
              <Groups view={view} ctx={ctx} />
            </div>
            <ChangesFold changes={view.changes} hidden={view.underTheHood} strings={strings} open={view.count === 0} />
          </>
        )}
      </article>
    </div>
  );
}
