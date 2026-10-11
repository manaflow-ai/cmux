// Design A, Journal (cx-urd.61, Lawrence picked 2026-10-11): one calm column, releases stacked
// newest first. Each release: quiet date and version, its lead change as the headline with one
// paragraph, the media and its action, then New / Improved / Fixed as one-line rows, and the
// commit list folded. An update's span comes first under "Since your last update". J and K move
// between releases. Notes load as a release nears the viewport.
import type { KeyboardEvent } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import type { Strings } from "../shared/i18n";
import { releaseView } from "./model";
import { ChangesFold, Groups, Hero, ReleaseMeta, type PartsContext } from "./ReleaseParts";
import type { ChangelogSnapshot, ChangelogStore } from "./store";
import type { IndexEntry } from "./types";

export function JournalPage({ store, strings, s }: { store: ChangelogStore; strings: Strings; s: ChangelogSnapshot }) {
  const ctx: PartsContext = { strings, onTry: (id) => void store.tryIt(id) };
  const span = new Set(s.inSpan);
  const fresh = s.builds.filter((b) => span.has(b.build));
  const earlier = s.builds.filter((b) => !span.has(b.build));
  const section = (entry: IndexEntry) => (
    <ReleaseSection
      key={entry.build}
      entry={entry}
      s={s}
      store={store}
      ctx={ctx}
      installed={entry.build === s.current}
    />
  );
  return (
    <KeyboardScope className="clj" handleKeyDown={journalKeys}>
      <main aria-label={strings.t("changelog.page.title")}>
        {s.failed && <p className="cl-error">{s.failed}</p>}
        {s.span && fresh.length === 0 && (
          <h1 className="cl-updated" data-testid="changelog.updatedTo">
            {strings.format("changelog.page.updatedTo", s.span.to)}
          </h1>
        )}
        {s.builds.length === 0 && <p className="cl-muted">{strings.t("changelog.page.noHistory")}</p>}
        {fresh.length > 0 && (
          <div className="clj-marker clj-marker-span" data-testid="changelog.sinceLastUpdate">
            {strings.t("changelog.page.sinceLastUpdate")}
          </div>
        )}
        {fresh.map(section)}
        {fresh.length > 0 && earlier.length > 0 && (
          <div className="clj-marker">{strings.t("changelog.page.earlier")}</div>
        )}
        {earlier.map(section)}
      </main>
    </KeyboardScope>
  );
}

function ReleaseSection({
  entry,
  s,
  store,
  ctx,
  installed,
}: {
  entry: IndexEntry;
  s: ChangelogSnapshot;
  store: ChangelogStore;
  ctx: PartsContext;
  installed: boolean;
}) {
  const notes = s.loaded[entry.build];
  const near = (el: HTMLElement | null) => {
    if (!el || notes || s.unavailable[entry.build]) return;
    if (typeof IntersectionObserver === "undefined") {
      void store.ensure(entry.build);
      return;
    }
    const observer = new IntersectionObserver(
      (records) => {
        if (records.some((r) => r.isIntersecting)) {
          observer.disconnect();
          void store.ensure(entry.build);
        }
      },
      { rootMargin: "800px 0px" },
    );
    observer.observe(el);
    return () => observer.disconnect();
  };
  const view = notes ? releaseView(notes, ctx.strings.language) : undefined;
  return (
    <article
      className={`clj-release${view?.hero ? "" : " is-compact"}`}
      ref={near}
      data-build={entry.build}
      aria-label={entry.shortVersion}
    >
      <div className="cl-meta-row">
        <ReleaseMeta date={entry.date} version={entry.shortVersion} strings={ctx.strings} />
        {installed && <span className="cl-installed">{ctx.strings.t("changelog.page.current")}</span>}
      </div>
      {!notes && !s.unavailable[entry.build] && <div className="clj-placeholder" aria-busy="true" />}
      {!notes && s.unavailable[entry.build] && (
        <p className="cl-muted">{ctx.strings.t("changelog.page.unavailable")}</p>
      )}
      {view?.hero && <Hero item={view.hero} ctx={ctx} />}
      {view && <Groups view={view} ctx={ctx} />}
      {view && <ChangesFold changes={view.changes} strings={ctx.strings} />}
    </article>
  );
}

/** J and K (from any focused control in the page) jump to the next or previous release. The
    document scrolls, so Space, Page Down and the arrows work with nothing focused. */
function journalKeys(event: KeyboardEvent<HTMLDivElement>) {
  if (event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
  const key = event.key.toLowerCase();
  if (key !== "j" && key !== "k") return;
  const doc = event.currentTarget.ownerDocument;
  const releases = [...event.currentTarget.querySelectorAll<HTMLElement>(".clj-release")];
  // A release scrolled into view rests at the scroll padding, not at 0.
  const padding = Number.parseFloat(doc.defaultView?.getComputedStyle(doc.documentElement).scrollPaddingTop ?? "") || 0;
  const top = (r: HTMLElement) => r.getBoundingClientRect().top - padding;
  const target = key === "j" ? releases.find((r) => top(r) > 8) : [...releases].reverse().find((r) => top(r) < -8);
  if (!target) return;
  event.preventDefault();
  const reduce = doc.defaultView?.matchMedia("(prefers-reduced-motion: reduce)").matches;
  target.scrollIntoView({ block: "start", behavior: reduce ? "auto" : "smooth" });
  target.querySelector<HTMLElement>("button, a[href], summary")?.focus({ preventScroll: true });
}
