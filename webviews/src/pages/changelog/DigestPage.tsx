// Design C, Digest (cx-urd.61; Debug Settings `whatsNew.design = digest`, kept until the journal
// has been dogfooded): no hero; each release a date heading and a dense, ruled list with a
// category column and a small thumbnail where a change has media.
import type { Strings } from "../shared/i18n";
import { formatReleaseDate, releaseView, type ReleaseItem } from "./model";
import { categoryLabel, ChangesFold, Media, RowActions, type PartsContext } from "./ReleaseParts";
import { ChangePullRequest } from "./ChangePullRequest";
import type { ChangelogSnapshot, ChangelogStore } from "./store";
import type { IndexEntry } from "./types";

export function DigestPage({ store, strings, s }: { store: ChangelogStore; strings: Strings; s: ChangelogSnapshot }) {
  const ctx: PartsContext = { strings, onTry: (id) => void store.tryIt(id) };
  return (
    <main className="cld" aria-label={strings.t("changelog.page.title")}>
      {s.failed && <p className="cl-error">{s.failed}</p>}
      {s.span && s.inSpan.length === 0 && (
        <h1 className="cl-updated" data-testid="changelog.updatedTo">
          {strings.format("changelog.page.updatedTo", s.span.to)}
        </h1>
      )}
      {s.builds.length === 0 && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
      {s.builds.map((entry) => (
        <DigestRelease key={entry.build} entry={entry} s={s} store={store} ctx={ctx} />
      ))}
    </main>
  );
}

function DigestRelease({
  entry,
  s,
  store,
  ctx,
}: {
  entry: IndexEntry;
  s: ChangelogSnapshot;
  store: ChangelogStore;
  ctx: PartsContext;
}) {
  const notes = s.loaded[entry.build];
  const near = (el: HTMLElement | null) => {
    if (!el || notes || s.unavailable[entry.build]) return;
    if (typeof IntersectionObserver === "undefined") return void store.ensure(entry.build);
    const observer = new IntersectionObserver(
      (records) => {
        if (!records.some((r) => r.isIntersecting)) return;
        observer.disconnect();
        void store.ensure(entry.build);
      },
      { rootMargin: "800px 0px" },
    );
    observer.observe(el);
    return () => observer.disconnect();
  };
  const view = notes ? releaseView(notes, ctx.strings.language) : undefined;
  const items: ReleaseItem[] = view ? [...(view.hero ? [view.hero] : []), ...view.groups.flatMap((g) => g.items)] : [];
  return (
    <section className="cld-release" ref={near} aria-label={entry.shortVersion}>
      <header className="cld-head">
        <h2>{formatReleaseDate(entry.date, ctx.strings.language)}</h2>
        {s.inSpan.includes(entry.build) && (
          <span className="cld-span">{ctx.strings.t("changelog.page.sinceLastUpdate")}</span>
        )}
        <span className="cld-version">{entry.shortVersion}</span>
      </header>
      {!notes && s.unavailable[entry.build] && (
        <p className="cl-muted">{ctx.strings.t("changelog.page.unavailable")}</p>
      )}
      {items.map((item) => (
        <div key={item.id} className="cld-item">
          <span className="cld-cat">{categoryLabel(ctx.strings, item.category)}</span>
          <div>
            {item.pr ? (
              <ChangePullRequest pr={item.pr} title={item.title} />
            ) : (
              <span className="cl-row-title">{item.title}</span>
            )}
            {item.summary && <span className="cl-row-summary">{item.summary.split(/\n{2,}/)[0]}</span>}
            <RowActions item={item} ctx={ctx} />
          </div>
          {item.media ? <Media media={item.media} className="cld-thumb" strings={ctx.strings} /> : <span />}
        </div>
      ))}
      {view && <ChangesFold changes={view.changes} hidden={view.underTheHood} strings={ctx.strings} />}
    </section>
  );
}
