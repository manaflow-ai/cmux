// The pieces every changelog design shares (cx-urd.61): release meta, the hero, the grouped
// change rows and the folded commit list. Colors are theme tokens, sizes the type scale
// (styles.css); nothing here knows which design it sits in.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { formatReleaseDate, type MediaRef, type ReleaseItem, type ReleaseView } from "./model";
import type { WhatsNewCategory } from "./types";

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
        <a className="cl-link" href={item.docs} rel="noreferrer">
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

/** New / Improved / Fixed / Security, each a short list of one-line rows (title, then its summary). */
export function Groups({ view, ctx }: { view: ReleaseView; ctx: PartsContext }) {
  return (
    <>
      {view.groups.map((group) => (
        <section key={group.category} className="cl-group" aria-label={categoryLabel(ctx.strings, group.category)}>
          <h3>{categoryLabel(ctx.strings, group.category)}</h3>
          <ul>
            {group.items.map((item) => (
              <li key={item.id}>
                <span className="cl-row-title">{item.title}</span>
                {item.summary && <span className="cl-row-summary">{item.summary.split(/\n{2,}/)[0]}</span>}
                {item.action && (
                  <button type="button" className="cl-row-action" onClick={() => ctx.onTry(item.action!.id)}>
                    {item.action.title || ctx.strings.t("changelog.page.tryIt")}
                  </button>
                )}
              </li>
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}

/** The commit subjects, folded: the full history for whoever wants it, out of the way otherwise. */
export function ChangesFold({ changes, strings, open }: { changes: string[]; strings: Strings; open?: boolean }) {
  if (changes.length === 0) return null;
  return (
    <details className="cl-changes" open={open}>
      <summary>
        {strings.t("changelog.page.allChanges")}
        <span className="cl-count">{changes.length}</span>
      </summary>
      <ul>
        {changes.map((c, i) => (
          <li key={i}>{c}</li>
        ))}
      </ul>
    </details>
  );
}
