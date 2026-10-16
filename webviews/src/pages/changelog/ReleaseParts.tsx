// The pieces every changelog design shares (cx-urd.61): release meta, the hero, the grouped
// change rows and the folded commit list. Colors are theme tokens, sizes the type scale
// (styles.css); nothing here knows which design it sits in.
import { useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { formatReleaseDate, type MediaRef, type ReleaseItem, type ReleaseView } from "./model";
import type { ChangeItem, WhatsNewCategory } from "./types";

export interface PartsContext {
  strings: Strings;
  onTry: (action: string) => void;
}

export function categoryLabel(strings: Strings, category: WhatsNewCategory): string {
  return strings.t(`changelog.group.${category}`);
}

/** "Oct 11 · 1.0.0-nightly.413", quiet. */
export function ReleaseMeta({ date, version, strings }: { date: string; version: string; strings: Strings }) {
  return (
    <div className="cl-meta">
      <time dateTime={date}>{formatReleaseDate(date, strings.language)}</time>
      <span aria-hidden="true">·</span>
      <span>{version}</span>
    </div>
  );
}

/** The release's picture in the theme's scheme; the box keeps its ratio before the file arrives. */
export function Media({ media, className }: { media: MediaRef; className?: string }) {
  const scheme = useSyncExternalStore(subscribeColorScheme, getColorScheme, () => "light" as const);
  const src = scheme === "dark" ? media.dark : media.light;
  return (
    <figure className={`cl-media${className ? ` ${className}` : ""}`}>
      {media.video ? (
        <video key={src} src={src} aria-label={media.alt} muted loop playsInline autoPlay preload="none" />
      ) : (
        <img key={src} src={src} alt={media.alt} loading="lazy" decoding="async" />
      )}
    </figure>
  );
}

export function ItemActions({ item, ctx }: { item: ReleaseItem; ctx: PartsContext }) {
  if (!item.action && !item.docs) return null;
  return (
    <div className="cl-actions">
      {item.action && (
        <button type="button" className="cl-button" onClick={() => ctx.onTry(item.action!.id)}>
          {item.action.title || ctx.strings.t("changelog.page.tryIt")}
        </button>
      )}
      {item.docs && (
        <a
          className="cl-link"
          href={item.docs}
          rel="noreferrer"
          aria-label={`${ctx.strings.t("changelog.page.learnMore")}: ${item.title}`}
        >
          {ctx.strings.t("changelog.page.learnMore")}
        </a>
      )}
    </div>
  );
}

/** Actions on a grouped change stay with its title and summary instead of hiding on hover. */
export function RowActions({ item, ctx }: { item: ReleaseItem; ctx: PartsContext }) {
  if (!item.action && !item.docs) return null;
  return (
    <div className="cl-row-actions">
      {item.action && (
        <button type="button" className="cl-row-action" onClick={() => ctx.onTry(item.action!.id)}>
          {item.action.title || ctx.strings.t("changelog.page.tryIt")}
        </button>
      )}
      {item.docs && (
        <a
          className="cl-row-link"
          href={item.docs}
          rel="noreferrer"
          aria-label={`${ctx.strings.t("changelog.page.learnMore")}: ${item.title}`}
        >
          {ctx.strings.t("changelog.page.learnMore")}
        </a>
      )}
    </div>
  );
}

/** The lead change: headline, one paragraph, media, its action. */
export function Hero({ item, ctx, level = 2 }: { item: ReleaseItem; ctx: PartsContext; level?: 1 | 2 }) {
  const Heading = level === 1 ? "h1" : "h2";
  return (
    <>
      <Heading className="cl-headline">{item.title}</Heading>
      {item.summary
        .split(/\n{2,}/)
        .filter(Boolean)
        .map((p, i) => (
          <p key={i} className="cl-lede">
            {p}
          </p>
        ))}
      {item.media && <Media media={item.media} />}
      <ItemActions item={item} ctx={ctx} />
    </>
  );
}

/** New / Improved / Fixed / Security, each a short list of one-line rows (title, then its
    summary), the first GROUP_PAGE of each with "Show more" for the rest. */
export function Groups({ view, ctx }: { view: ReleaseView; ctx: PartsContext }) {
  return (
    <>
      {view.groups.map((group) => (
        <Group key={group.category} category={group.category} items={group.items} ctx={ctx} />
      ))}
    </>
  );
}

const GROUP_PAGE = 5;

function Group({ category, items, ctx }: { category: WhatsNewCategory; items: ReleaseItem[]; ctx: PartsContext }) {
  const [all, setAll] = useState(false);
  const shown = all ? items : items.slice(0, GROUP_PAGE);
  return (
    <section className="cl-group" aria-label={categoryLabel(ctx.strings, category)}>
      <h3>{categoryLabel(ctx.strings, category)}</h3>
      <ul>
        {shown.map((item, index) => (
          <li key={`${item.id}-${index}`}>
            <div className="cl-row-copy">
              <span className="cl-row-title">{item.title}</span>
              {item.summary && <span className="cl-row-summary">{item.summary.split(/\n{2,}/)[0]}</span>}
            </div>
            <RowActions item={item} ctx={ctx} />
          </li>
        ))}
      </ul>
      {!all && items.length > GROUP_PAGE && (
        <button type="button" className="cl-more" onClick={() => setAll(true)}>
          {ctx.strings.t("changelog.page.showMore")}
        </button>
      )}
    </section>
  );
}

/** Every change, folded: readable titles with their pull request linked, 20 at a time. */
export function ChangesFold({ changes, strings, open }: { changes: ChangeItem[]; strings: Strings; open?: boolean }) {
  const [shown, setShown] = useState(CHANGES_PAGE);
  if (changes.length === 0) return null;
  return (
    <details className="cl-changes" open={open}>
      <summary>
        {strings.t("changelog.page.allChanges")}
        <span className="cl-count">{changes.length}</span>
      </summary>
      <ul>
        {changes.slice(0, shown).map((c, i) => (
          <li key={c.pr ?? `t${i}`}>
            <span>{c.title}</span>
            {c.pr !== undefined && (
              <a className="cl-pr" href={`https://github.com/manaflow-ai/cmux/pull/${c.pr}`} rel="noreferrer">
                #{c.pr}
              </a>
            )}
          </li>
        ))}
      </ul>
      {shown < changes.length && (
        <button type="button" className="cl-more" onClick={() => setShown((n) => n + CHANGES_PAGE * 2)}>
          {strings.t("changelog.page.showMore")}
        </button>
      )}
    </details>
  );
}

const CHANGES_PAGE = 20;

/** A run of builds with no change a person would notice: one quiet line, never a blank row. */
export function Maintenance({ strings }: { strings: Strings }) {
  return <p className="cl-maintenance">{strings.t("changelog.page.maintenance")}</p>;
}

/** The build numbers of a section, small and selectable (copy one with a double click). */
export function BuildNumbers({ builds }: { builds: { build: string; shortVersion: string }[] }) {
  return (
    <div className="cl-builds">
      {builds.map((b, i) => (
        <span key={b.build}>
          {i > 0 && <span aria-hidden="true"> · </span>}
          <span className="cl-build">{b.shortVersion}</span>
        </span>
      ))}
    </div>
  );
}
