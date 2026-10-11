import {
  localizedText,
  webTryItLink,
  whatsNewCategories,
  whatsNewMediaBase,
  type WhatsNewDocument,
  type WhatsNewEntry,
} from "@/app/lib/whats-new";

export type WhatsNewLabels = {
  categories: Record<WhatsNewDocument["entries"][number]["category"], string>;
  channels: Record<WhatsNewDocument["channel"], string>;
  audiences: { teams: string; enterprise: string };
  platforms: Record<string, string>;
  openInCmux: string;
  learnMore: string;
};

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

/** One release's What's New: headline, date, channel, then entries by category. */
export function WhatsNewDocumentView({
  document,
  locale,
  labels,
  headingLevel = 1,
  versionHref,
}: {
  document: WhatsNewDocument;
  locale: string;
  labels: WhatsNewLabels;
  headingLevel?: 1 | 2;
  versionHref?: string;
}) {
  const Heading = headingLevel === 1 ? "h1" : "h2";
  const headline = localizedText(document.headline, locale);
  return (
    <article className="flex flex-col gap-6 pb-10" aria-labelledby={`whats-new-${document.version}`}>
      <header className="flex flex-col gap-2">
        <div className="flex items-center gap-3 text-[13px] text-muted">
          <span>cmux {document.version}</span>
          <span aria-hidden>·</span>
          <time dateTime={document.date}>{formatDate(document.date, locale)}</time>
          {document.channel !== "stable" && (
            <span className="rounded-full border border-border px-2 py-[1px] text-[12px]">
              {labels.channels[document.channel]}
            </span>
          )}
        </div>
        <Heading id={`whats-new-${document.version}`} className="text-2xl font-semibold tracking-tight">
          {versionHref ? (
            <a href={versionHref} className="hover:opacity-80 transition-opacity" style={{ textDecoration: "none" }}>
              {headline}
            </a>
          ) : (
            headline
          )}
        </Heading>
      </header>
      {whatsNewCategories.map((category) => {
        const entries = document.entries.filter((entry) => entry.category === category);
        if (entries.length === 0) return null;
        return (
          <section key={category} className="flex flex-col gap-5">
            <h3 className="text-[13px] font-semibold text-muted">{labels.categories[category]}</h3>
            {entries.map((entry) => (
              <WhatsNewEntryView key={entry.id} entry={entry} locale={locale} labels={labels} />
            ))}
          </section>
        );
      })}
    </article>
  );
}

function WhatsNewEntryView({ entry, locale, labels }: { entry: WhatsNewEntry; locale: string; labels: WhatsNewLabels }) {
  const deeplink = webTryItLink(entry);
  const audience = entry.audience === "all" ? undefined : labels.audiences[entry.audience];
  const platforms = entry.platforms.map((platform) => labels.platforms[platform] ?? platform).join(" · ");
  return (
    <div id={entry.id} className="flex flex-col gap-2">
      {entry.media && <WhatsNewMedia media={entry.media} alt={localizedText(entry.media.alt, locale)} />}
      <div className="flex flex-wrap items-baseline gap-2">
        <h4 className="text-[15px] font-semibold">{localizedText(entry.title, locale)}</h4>
        {audience && (
          <span className="rounded-full border border-border px-2 py-[1px] text-[12px] text-muted">{audience}</span>
        )}
      </div>
      <p className="text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
        {localizedText(entry.summary, locale)}
      </p>
      <div className="flex flex-wrap items-center gap-4 text-[13px] text-muted">
        <span>{platforms}</span>
        {deeplink && (
          <a href={deeplink} className={linkClass}>
            {labels.openInCmux}
          </a>
        )}
        {entry.docs && (
          <a href={entry.docs} className={linkClass}>
            {labels.learnMore}
          </a>
        )}
      </div>
    </div>
  );
}

/** Light and dark media; the site's theme (the `dark` class) picks one. */
function WhatsNewMedia({ media, alt }: { media: NonNullable<WhatsNewEntry["media"]>; alt: string }) {
  const light = whatsNewMediaBase + media.light;
  const dark = whatsNewMediaBase + media.dark;
  const frame = "w-full rounded-lg border border-border overflow-hidden";
  if (media.kind === "video") {
    return (
      <>
        <video className={`${frame} dark:hidden`} src={light} controls muted playsInline preload="metadata" aria-label={alt} />
        <video className={`${frame} hidden dark:block`} src={dark} controls muted playsInline preload="metadata" aria-label={alt} />
      </>
    );
  }
  return (
    <>
      <img className={`${frame} dark:hidden`} src={light} alt={alt} loading="lazy" decoding="async" />
      <img className={`${frame} hidden dark:block`} src={dark} alt={alt} loading="lazy" decoding="async" />
    </>
  );
}

function formatDate(date: string, locale: string): string {
  const parsed = new Date(`${date}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return date;
  return new Intl.DateTimeFormat(locale, { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" }).format(parsed);
}
