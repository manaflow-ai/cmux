// The pieces every changelog design shares (cx-urd.61): release meta, the hero, the grouped
// change rows and the folded commit list by area. Colors are theme tokens, sizes the type scale
// (styles.css); nothing here knows which design it sits in.
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { byArea } from "./areas";
import { formatReleaseDate, type AreaChange, type MediaRef, type ReleaseItem, type ReleaseView } from "./model";
import type { ChangeItem, NewsLayout, WhatsNewCategory } from "./types";
import { ChangePullRequest } from "./ChangePullRequest";

export interface PartsContext {
  strings: Strings;
  onTry: (action: string) => void;
  /** Each change is a wide row with its whole description and its picture beside it (the Ledger). */
  rowMedia?: boolean;
  /** How the update's news shows its clips (SpanNews.tsx); grid when unset. */
  news?: NewsLayout;
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

/** The release's picture in the theme's scheme, whole at its own shape; its frame is the picture's
    box (styles.css .cl-media, #29876). A picture the host inlined (a data: URL, every verified one)
    is already in memory, so it loads at once and the page never moves under it; any other loads as
    it nears the viewport. Given `strings`, a click (or Return) opens it enlarged. */
export function Media({ media, className, strings }: { media: MediaRef; className?: string; strings?: Strings }) {
  const scheme = useSyncExternalStore(subscribeColorScheme, getColorScheme, () => "light" as const);
  const src = scheme === "dark" ? media.dark : media.light;
  const [open, setOpen] = useState(false);
  const picture = media.video ? (
    <LazyVideo key={src} src={src} alt={media.alt} />
  ) : (
    <img key={src} src={src} alt={media.alt} loading={src.startsWith("data:") ? "eager" : "lazy"} decoding="async" />
  );
  return (
    <figure className={`cl-media ui-glass${className ? ` ${className}` : ""}`}>
      {strings ? (
        <button
          type="button"
          className="cl-media-open"
          aria-label={
            media.alt ? `${strings.t("changelog.page.enlarge")}: ${media.alt}` : strings.t("changelog.page.enlarge")
          }
          onClick={() => setOpen(true)}
        >
          {picture}
        </button>
      ) : (
        picture
      )}
      {strings && open && <MediaLightbox media={media} src={src} strings={strings} onClose={() => setOpen(false)} />}
    </figure>
  );
}

/** Autoplay overrides preload in browsers, so withhold the source until the clip is nearby. */
function LazyVideo({ src, alt }: { src: string; alt: string }) {
  const player = useRef<HTMLVideoElement>(null);
  const [near, setNear] = useState(false);
  useEffect(() => {
    const element = player.current;
    if (!element) return;
    if (typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        observer.disconnect();
        setNear(true);
      },
      { rootMargin: "200px 0px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return (
    <video
      ref={player}
      src={near ? src : undefined}
      aria-label={alt}
      muted
      loop
      playsInline
      autoPlay={near}
      preload="none"
    />
  );
}

/** A picture enlarged to the window, on glass over the page; Escape, Close or a press outside closes it. */
function MediaLightbox({
  media,
  src,
  strings,
  onClose,
}: {
  media: MediaRef;
  src: string;
  strings: Strings;
  onClose(): void;
}) {
  const close = useRef<HTMLButtonElement | null>(null);
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && onClose()}
      label={media.alt}
      className="cl-lightbox"
      backdropClassName="cl-lightbox-backdrop"
      initialFocus={close}
    >
      <header className="cl-lightbox-bar">
        <span className="cl-lightbox-alt">{media.alt}</span>
        <DialogButton ref={close} dialogKey="escape" className="cl-button" onClick={onClose}>
          {strings.t("changelog.page.close")}
        </DialogButton>
      </header>
      <div className="cl-lightbox-stage">
        {media.video ? (
          <video src={src} aria-label={media.alt} muted loop playsInline autoPlay controls />
        ) : (
          <img src={src} alt={media.alt} />
        )}
      </div>
    </Dialog>
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

/** Try it and Learn more for one grouped change, kept with its title and summary. A span: the
    Ledger puts it inside a paragraph, where a div is invalid. */
export function RowActions({ item, ctx }: { item: ReleaseItem; ctx: PartsContext }) {
  if (!item.action && !item.docs) return null;
  return (
    <span className="cl-row-actions">
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
    </span>
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
        <Heading className="cl-headline">
          {item.pr ? <ChangePullRequest pr={item.pr} title={item.title} /> : item.title}
        </Heading>
      ) : (
        <h3 className="cl-row-title cll-lead">
          {item.pr ? <ChangePullRequest pr={item.pr} title={item.title} /> : item.title}
        </h3>
      )}
      {item.summary
        .split(/\n{2,}/)
        .filter(Boolean)
        .map((p, i) => (
          <p key={i} className="cl-lede">
            {p}
          </p>
        ))}
      {item.media && <Media media={item.media} strings={ctx.strings} />}
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
        {shown.map((item, index) =>
          ctx.rowMedia ? (
            <WideRow key={`${item.id}-${index}`} item={item} ctx={ctx} />
          ) : (
            <li key={`${item.id}-${index}`}>
              <span className="cl-row-text">
                {item.pr ? (
                  <ChangePullRequest pr={item.pr} title={item.title} />
                ) : (
                  <span className="cl-row-title">{item.title}</span>
                )}
                {item.summary && <span className="cl-row-summary"> {item.summary.split(/\n{2,}/)[0]}</span>}
              </span>
              <RowActions item={item} ctx={ctx} />
            </li>
          ),
        )}
      </ul>
      {!all && items.length > GROUP_PAGE && (
        <button type="button" className="cl-more" onClick={() => setAll(true)}>
          {ctx.strings.t("changelog.page.showMore")}
        </button>
      )}
    </section>
  );
}

/** A change in the Ledger, which uses the pane's width: its title, then its whole description, and
    its picture beside them when the pane has room (under them when it does not). Its actions end
    the last line (#21185: a box of their own would leave an empty line under every row). */
function WideRow({ item, ctx }: { item: ReleaseItem; ctx: PartsContext }) {
  const paragraphs = item.summary.split(/\n{2,}/).filter(Boolean);
  const actions = <RowActions item={item} ctx={ctx} />;
  return (
    <li className={item.media ? "cl-wide-row cl-has-media" : "cl-wide-row"}>
      <div className="cl-row-text">
        {item.pr ? (
          <ChangePullRequest pr={item.pr} title={item.title} />
        ) : (
          <span className="cl-row-title">{item.title}</span>
        )}
        {paragraphs.length === 0 && actions}
        {paragraphs.map((p, i) => (
          <p key={i} className="cl-row-summary">
            {p}
            {i === paragraphs.length - 1 && actions}
          </p>
        ))}
      </div>
      {item.media && <Media media={item.media} className="cl-row-media" strings={ctx.strings} />}
    </li>
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
          {c.pr === undefined ? <span>{c.title}</span> : <ChangePullRequest pr={c.pr} title={c.title} />}
        </li>
      ))}
    </ul>
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
