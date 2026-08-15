import Image from "next/image";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import type { ChangelogVersion } from "@/app/lib/changelog";
import { pngDimensions } from "./png-dimensions";
import type { VersionMedia } from "./changelog-media";

export interface ChangelogSectionLabels {
  added: string;
  changed: string;
  fixed: string;
  removed: string;
  contributors: string;
}

export function ChangelogRelease({
  release,
  locale,
  media,
  sectionLabels,
  standaloneHeading,
  versionHref,
  standalone = false,
  first = false,
}: {
  release: ChangelogVersion;
  locale: string;
  media?: VersionMedia;
  sectionLabels: ChangelogSectionLabels;
  standaloneHeading?: string;
  versionHref?: string;
  standalone?: boolean;
  first?: boolean;
}) {
  const heading =
    standaloneHeading ??
    (locale === "en" && media?.title
      ? `cmux ${release.version}: ${media.title}`
      : `cmux ${release.version}`);

  return (
    <article
      id={standalone ? undefined : `v${release.version}`}
      className={
        standalone
          ? undefined
          : "border-t border-border first:border-t-0"
      }
      style={{
        display: "flex",
        flexDirection: "column",
        paddingTop: standalone || first ? 0 : 40,
        paddingBottom: 40,
      }}
    >
      {standalone ? (
        <>
          <DocsHeading
            level={1}
            id={`v${release.version}`}
            className="docs-heading-compact"
          >
            {heading}
          </DocsHeading>
          <time
            className="text-[13px] text-muted"
            dateTime={release.date}
            style={{ paddingTop: 8 }}
          >
            {formatDate(release.date, locale)}
          </time>
        </>
      ) : (
        <>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            {versionHref ? (
              <a
                href={versionHref}
                className="no-underline! hover:no-underline!"
              >
                <VersionBadge version={release.version} />
              </a>
            ) : (
              <VersionBadge version={release.version} />
            )}
            <time className="text-[13px] text-muted" dateTime={release.date}>
              {formatDate(release.date, locale)}
            </time>
          </div>

          {media?.title && (
            <div
              className="max-w-full"
              style={{
                paddingTop: 12,
                margin: 0,
                fontSize: "1.5rem",
                fontWeight: 700,
                letterSpacing: 0,
                lineHeight: 1.25,
                overflowWrap: "anywhere",
              }}
            >
              {versionHref ? (
                <a
                  href={versionHref}
                  className="text-foreground no-underline! hover:no-underline!"
                >
                  {media.title}
                </a>
              ) : (
                media.title
              )}
            </div>
          )}
        </>
      )}

      {media?.hero && (
        <HeroImage
          src={media.hero}
          version={release.version}
          priority={standalone || first}
        />
      )}

      {media && <FeatureList media={media} />}

      {release.intro && !media && (
        <div
          className="text-[14px] text-muted italic"
          style={{ paddingTop: 12 }}
        >
          {release.intro.replace(/^_/, "").replace(/_$/, "")}
        </div>
      )}

      <div
        style={{
          paddingTop: 20,
          display: "flex",
          flexDirection: "column",
          gap: 16,
        }}
      >
        {release.sections.map((section, index) => {
          const isContributors = section.heading
            .toLowerCase()
            .startsWith("thanks");

          if (isContributors) {
            return (
              <div key={index}>
                <SectionBadge
                  heading={section.heading}
                  labels={sectionLabels}
                />
                <ContributorList items={section.items} />
              </div>
            );
          }

          return (
            <div key={index}>
              {section.heading && (
                <SectionBadge
                  heading={section.heading}
                  labels={sectionLabels}
                />
              )}
              <ul
                style={{
                  margin: 0,
                  paddingTop: 8,
                  paddingBottom: 0,
                  paddingLeft: 24,
                  listStyle: "disc",
                }}
              >
                {section.items.map((item, itemIndex) => (
                  <li
                    key={itemIndex}
                    style={{
                      margin: 0,
                      padding: 0,
                      fontSize: 14,
                      lineHeight: 1.6,
                      color: "var(--muted)",
                    }}
                  >
                    <InlineMarkdown text={item} />
                  </li>
                ))}
              </ul>
            </div>
          );
        })}
      </div>
    </article>
  );
}

function VersionBadge({ version }: { version: string }) {
  return (
    <span className="inline-block text-[13px] font-mono text-muted bg-code-bg px-2 py-0.5 rounded-md">
      {version}
    </span>
  );
}

function InlineMarkdown({ text }: { text: string }) {
  const parts = text.split(/(`[^`]+`|\[[^\]]+\]\([^)]+\))/g);
  return (
    <>
      {parts.map((part, index) => {
        if (part.startsWith("`") && part.endsWith("`")) {
          return <code key={index}>{part.slice(1, -1)}</code>;
        }
        const linkMatch = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
        if (linkMatch) {
          return (
            <a key={index} href={linkMatch[2]}>
              {linkMatch[1]}
            </a>
          );
        }
        return <span key={index}>{part}</span>;
      })}
    </>
  );
}

function formatDate(date: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, {
    month: "long",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(`${date}T00:00:00Z`));
}

function HeroImage({
  src,
  version,
  priority,
}: {
  src: string;
  version: string;
  priority: boolean;
}) {
  const { width, height } = pngDimensions(src);
  return (
    <div style={{ paddingTop: 16, paddingBottom: 24 }}>
      <div className="overflow-hidden rounded-lg">
        <Image
          src={src}
          alt={`cmux ${version}`}
          width={width}
          height={height}
          sizes="(max-width: 640px) 100vw, 640px"
          className="w-full h-auto"
          priority={priority}
        />
      </div>
    </div>
  );
}

function FeatureImage({ src, alt }: { src: string; alt: string }) {
  const { width, height } = pngDimensions(src);
  return (
    <div style={{ paddingTop: 12 }}>
      <div className="overflow-hidden rounded-lg">
        <Image
          src={src}
          alt={alt}
          width={width}
          height={height}
          sizes="(max-width: 640px) 100vw, 640px"
          className="block w-full max-w-full h-auto"
        />
      </div>
    </div>
  );
}

function FeatureList({ media }: { media: VersionMedia }) {
  if (!media.features?.length) return null;

  return (
    <div
      style={{
        paddingTop: 20,
        display: "flex",
        flexDirection: "column",
        gap: 24,
      }}
    >
      {media.features.map((feature, index) => (
        <div key={index}>
          <p style={{ margin: 0, padding: 0 }}>
            <strong>{feature.title}.</strong>{" "}
            <span className="text-muted">{feature.description}</span>
          </p>
          {feature.image && (
            <FeatureImage src={feature.image} alt={feature.title} />
          )}
        </div>
      ))}
    </div>
  );
}

function ContributorList({ items }: { items: string[] }) {
  return (
    <div className="flex flex-wrap gap-2" style={{ paddingTop: 8 }}>
      {items.map((item, index) => {
        const match = item.match(
          /\[@([^\]]+)\]\((https:\/\/github\.com\/[^)]+)\)/,
        );
        if (match) {
          return (
            <a
              key={index}
              href={match[2]}
              className="inline-flex items-center gap-1.5 px-2 py-1 rounded-md border border-border text-[13px] text-muted hover:text-foreground transition-colors no-underline!"
            >
              <Image
                src={`https://github.com/${match[1]}.png?size=48`}
                alt={match[1]}
                width={18}
                height={18}
                className="rounded-full"
              />
              {match[1]}
            </a>
          );
        }
        return (
          <span key={index} className="text-[13px] text-muted">
            <InlineMarkdown text={item} />
          </span>
        );
      })}
    </div>
  );
}

function SectionBadge({
  heading,
  labels,
}: {
  heading: string;
  labels: ChangelogSectionLabels;
}) {
  const lower = heading.toLowerCase();

  let color = "bg-border/50 text-muted";
  let label = heading;

  if (lower === "added") {
    color = "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400";
    label = labels.added;
  } else if (lower === "changed") {
    color = "bg-blue-500/10 text-blue-600 dark:text-blue-400";
    label = labels.changed;
  } else if (lower === "fixed") {
    color = "bg-amber-500/10 text-amber-600 dark:text-amber-400";
    label = labels.fixed;
  } else if (lower === "removed") {
    color = "bg-red-500/10 text-red-600 dark:text-red-400";
    label = labels.removed;
  } else if (lower.startsWith("thanks")) {
    color = "bg-purple-500/10 text-purple-600 dark:text-purple-400";
    label = labels.contributors;
  }

  return (
    <span
      className={`inline-block text-[12px] font-medium px-2 py-0.5 rounded-md ${color}`}
    >
      {label}
    </span>
  );
}
