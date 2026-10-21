// The pieces every changelog design shares (cx-urd.61): release meta, the hero, the grouped
// change rows and the folded commit list by area. Colors are theme tokens, sizes the type scale
// (styles.css); nothing here knows which design it sits in.
import { useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { byArea } from "./areas";
import { formatReleaseDate, type AreaChange, type MediaRef, type ReleaseItem, type ReleaseView } from "./model";
import type { ChangeItem, IndexEntry, WhatsNewCategory } from "./types";
import { cardVersion } from "./UpdateSurfaces";

export interface PartsContext {
  strings: Strings;
  onTry: (action: string) => void;
  /** Each change with a picture shows it under its row (the Ledger: a visual per feature). */
  rowMedia?: boolean;
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

/** Try it and Learn more for one grouped change, kept with its title and summary. */
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
export function Hero({
  item,
  ctx,
  level = 2,
  titled = true,
}: {
  item: ReleaseItem;
  ctx: PartsContext;
  level?: 1 | 2;
  /** False when the release title above already says it (the Ledger). */
  titled?: boolean;
}) {
  const Heading = level === 1 ? "h1" : "h2";
  return (
    <>
      {titled ? (
        <Heading className="cl-headline">{item.title}</Heading>
      ) : (
        <h3 className="cl-row-title cll-lead">{item.title}</h3>
      )}
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
            <span className="cl-row-text">
              <span className="cl-row-title">{item.title}</span>
              {item.summary && <span className="cl-row-summary"> {item.summary.split(/\n{2,}/)[0]}</span>}
              {ctx.rowMedia && item.media && <Media media={item.media} className="cl-row-media" />}
            </span>
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

/** Every change a person would notice, folded: readable titles with their pull request linked,
    under the app area each names ("Sidebar", …, then "Other"), 20 at a time, and under them the
    internal ones, folded again: "Under the hood". A release of internal work alone shows no fold:
    the page already says "Maintenance and fixes". */
export function ChangesFold({
  changes,
  hidden = [],
  strings,
  open,
}: {
  changes: AreaChange[];
  hidden?: ChangeItem[];
  strings: Strings;
  open?: boolean;
}) {
  const [shown, setShown] = useState(CHANGES_PAGE);
  if (changes.length === 0) return null;
  const ordered = byArea(changes).flatMap((group) => group.items);
  return (
    <details className="cl-changes" open={open}>
      <summary>
        {strings.t("changelog.page.allChanges")}
        <span className="cl-count">{changes.length}</span>
      </summary>
      {byArea(ordered.slice(0, shown)).map((group) => {
        const label = group.area ? strings.t(`updates.area.${group.area}`) : strings.t("changelog.page.otherArea");
        return (
          <section key={group.area ?? ""} className="cl-area" aria-label={label}>
            <h4>{label}</h4>
            <ChangeList changes={group.items} />
          </section>
        );
      })}
      {shown < changes.length && (
        <button type="button" className="cl-more" onClick={() => setShown((n) => n + CHANGES_PAGE * 2)}>
          {strings.t("changelog.page.showMore")}
        </button>
      )}
      {hidden.length > 0 && (
        <details className="cl-hood">
          <summary>
            {strings.t("changelog.page.underTheHood")}
            <span className="cl-count">{hidden.length}</span>
          </summary>
          <ChangeList changes={hidden} />
        </details>
      )}
    </details>
  );
}

function ChangeList({ changes }: { changes: ChangeItem[] }) {
  return (
    <ul>
      {changes.map((c, i) => (
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
  );
}

const CHANGES_PAGE = 20;

/** The nightly reels of `builds` (in their order, newest first), one card each: a link to the
    video, which opens as links do (the host's link setting). Only an https reel is shown. */
export function ReelCards({
  builds,
  reels,
  strings,
}: {
  builds: IndexEntry[];
  reels: Record<string, string>;
  strings: Strings;
}) {
  const shown = builds.filter((b) => reels[b.build]?.startsWith("https://"));
  if (shown.length === 0) return null;
  return (
    <div className="cl-reels">
      {shown.map((b) => (
        <a key={b.build} className="cl-reel" href={reels[b.build]} rel="noreferrer">
          {strings.format("changelog.page.watchReel", cardVersion(b.shortVersion))}
        </a>
      ))}
    </div>
  );
}

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
