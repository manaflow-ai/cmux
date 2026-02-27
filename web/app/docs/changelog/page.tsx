import type { Metadata } from "next";
import fs from "fs";
import path from "path";
import Image from "next/image";
import { changelogMedia, type VersionMedia } from "./changelog-media";

export const metadata: Metadata = {
  title: "Changelog",
  description:
    "cmux release notes and version history. New features, bug fixes, and changes for the native macOS terminal.",
};

interface ChangelogSection {
  heading: string;
  items: string[];
}

interface ChangelogVersion {
  version: string;
  date: string;
  intro?: string;
  sections: ChangelogSection[];
}

function parseChangelog(markdown: string): ChangelogVersion[] {
  const versions: ChangelogVersion[] = [];
  let current: ChangelogVersion | null = null;
  let currentSection: ChangelogSection | null = null;

  for (const line of markdown.split("\n")) {
    const versionMatch = line.match(/^## \[(.+?)\] - (.+)$/);
    if (versionMatch) {
      if (current) versions.push(current);
      current = {
        version: versionMatch[1],
        date: versionMatch[2],
        sections: [],
      };
      currentSection = null;
      continue;
    }

    if (!current) continue;

    const sectionMatch = line.match(/^### (.+)$/);
    if (sectionMatch) {
      currentSection = { heading: sectionMatch[1], items: [] };
      current.sections.push(currentSection);
      continue;
    }

    const itemMatch = line.match(/^- (.+)$/);
    if (itemMatch) {
      if (currentSection) {
        currentSection.items.push(itemMatch[1]);
      } else {
        if (!current.sections.length) {
          currentSection = { heading: "", items: [] };
          current.sections.push(currentSection);
        }
        current.sections[current.sections.length - 1].items.push(
          itemMatch[1]
        );
      }
      continue;
    }

    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      current.intro = trimmed;
    }
  }

  if (current) versions.push(current);
  return versions;
}

function InlineMarkdown({ text }: { text: string }) {
  const parts = text.split(/(`[^`]+`|\[[^\]]+\]\([^)]+\))/g);
  return (
    <>
      {parts.map((part, i) => {
        if (part.startsWith("`") && part.endsWith("`")) {
          return <code key={i}>{part.slice(1, -1)}</code>;
        }
        const linkMatch = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
        if (linkMatch) {
          return (
            <a key={i} href={linkMatch[2]}>
              {linkMatch[1]}
            </a>
          );
        }
        return <span key={i}>{part}</span>;
      })}
    </>
  );
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

function HeroImage({ src, version }: { src: string; version: string }) {
  return (
    <div className="mt-4 mb-6 overflow-hidden rounded-lg border border-border">
      <Image
        src={src}
        alt={`cmux ${version}`}
        width={1600}
        height={900}
        className="w-full h-auto"
        priority
      />
    </div>
  );
}

function FeatureList({ media }: { media: VersionMedia }) {
  if (!media.features?.length) return null;

  return (
    <div className="mt-5 space-y-6">
      {media.features.map((feature, i) => (
        <div key={i}>
          <p className="!mb-0">
            <strong>{feature.title}.</strong>{" "}
            <span className="text-muted">{feature.description}</span>
          </p>
          {feature.image && (
            <Image
              src={feature.image}
              alt={feature.title}
              width={1200}
              height={675}
              className="w-full h-auto rounded-lg border border-border mt-3"
            />
          )}
        </div>
      ))}
    </div>
  );
}

function ContributorList({ items }: { items: string[] }) {
  return (
    <div className="flex flex-wrap gap-2 mt-2">
      {items.map((item, i) => {
        const match = item.match(
          /\[@([^\]]+)\]\((https:\/\/github\.com\/[^)]+)\)/
        );
        if (match) {
          return (
            <a
              key={i}
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
          <span key={i} className="text-[13px] text-muted">
            <InlineMarkdown text={item} />
          </span>
        );
      })}
    </div>
  );
}

function SectionBadge({ heading }: { heading: string }) {
  const lower = heading.toLowerCase();

  let color = "bg-border/50 text-muted";
  let label = heading;

  if (lower === "added") {
    color = "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400";
    label = "Added";
  } else if (lower === "changed") {
    color = "bg-blue-500/10 text-blue-600 dark:text-blue-400";
    label = "Changed";
  } else if (lower === "fixed") {
    color = "bg-amber-500/10 text-amber-600 dark:text-amber-400";
    label = "Fixed";
  } else if (lower.startsWith("thanks")) {
    color = "bg-purple-500/10 text-purple-600 dark:text-purple-400";
    label = "Contributors";
  }

  return (
    <span
      className={`inline-block text-[12px] font-medium px-2 py-0.5 rounded-md ${color}`}
    >
      {label}
    </span>
  );
}

export default function ChangelogPage() {
  const changelogPath = path.join(process.cwd(), "..", "CHANGELOG.md");
  const markdown = fs.readFileSync(changelogPath, "utf-8");
  const versions = parseChangelog(markdown);

  return (
    <div className="max-w-[640px]">
      <h1>Changelog</h1>
      <p>What&apos;s new in cmux.</p>

      <div className="mt-8">
        {versions.map((v) => {
          const media = changelogMedia[v.version];

          return (
            <article
              key={v.version}
              id={`v${v.version}`}
              className="relative border-t border-border py-10 first:border-t-0"
            >
              <div className="flex items-center gap-3">
                <a
                  href={`#v${v.version}`}
                  className="no-underline! hover:no-underline!"
                >
                  <span className="inline-block text-[13px] font-mono text-muted bg-code-bg px-2 py-0.5 rounded-md">
                    {v.version}
                  </span>
                </a>
                <time
                  className="text-[13px] text-muted"
                  dateTime={v.date}
                >
                  {formatDate(v.date)}
                </time>
              </div>

              {media?.title && (
                <h2 className="!mt-3 !mb-0 text-[1.5rem] font-bold tracking-tight">
                  {media.title}
                </h2>
              )}

              {media?.hero && (
                <HeroImage src={media.hero} version={v.version} />
              )}

              {media && <FeatureList media={media} />}

              {v.intro && !media && (
                <p className="text-[14px] text-muted italic mt-3 mb-0">
                  {v.intro.replace(/^_/, "").replace(/_$/, "")}
                </p>
              )}

              <div className="mt-5 space-y-4">
                {v.sections.map((section, i) => {
                  const isContributors = section.heading
                    .toLowerCase()
                    .startsWith("thanks");

                  if (isContributors) {
                    return (
                      <div key={i}>
                        <SectionBadge heading={section.heading} />
                        <ContributorList items={section.items} />
                      </div>
                    );
                  }

                  return (
                    <div key={i}>
                      {section.heading && (
                        <SectionBadge heading={section.heading} />
                      )}
                      <ul className="!mt-2 !mb-0">
                        {section.items.map((item, j) => (
                          <li key={j} className="text-[14px]">
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
        })}
      </div>
    </div>
  );
}
