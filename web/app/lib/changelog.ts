import fs from "node:fs";
import path from "node:path";

export interface ChangelogSection {
  heading: string;
  items: string[];
}

export interface ChangelogVersion {
  version: string;
  date: string;
  intro?: string;
  sections: ChangelogSection[];
}

export const changelogPath = "/docs/changelog";

let cachedChangelog: readonly ChangelogVersion[] | undefined;

export function parseChangelog(markdown: string): ChangelogVersion[] {
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
      if (!currentSection) {
        currentSection = { heading: "", items: [] };
        current.sections.push(currentSection);
      }
      currentSection.items.push(itemMatch[1]);
      continue;
    }

    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      current.intro = current.intro
        ? `${current.intro} ${trimmed}`
        : trimmed;
    }
  }

  if (current) versions.push(current);
  return versions;
}

export function readChangelog(): readonly ChangelogVersion[] {
  if (cachedChangelog) return cachedChangelog;

  cachedChangelog = parseChangelog(
    fs.readFileSync(resolveChangelogPath(), "utf-8"),
  );
  return cachedChangelog;
}

export function findChangelogVersion(
  version: string,
): ChangelogVersion | undefined {
  return readChangelog().find((release) => release.version === version);
}

export function changelogVersionPath(version: string): string {
  return `${changelogPath}/${encodeURIComponent(version)}`;
}

export function localizedChangelogPath(
  locale: string,
  version?: string,
): string {
  const releasePath = version ? changelogVersionPath(version) : changelogPath;
  return locale === "en" ? releasePath : `/${locale}${releasePath}`;
}

export function changelogVersionDescription(
  release: ChangelogVersion,
  featuredDescription?: string,
): string {
  const firstReleaseItem = release.sections
    .find(
      (section) =>
        !section.heading.toLowerCase().startsWith("thanks") &&
        section.items.length > 0,
    )
    ?.items[0];
  const source =
    featuredDescription ??
    firstReleaseItem ??
    release.intro ??
    "";
  const plainText = inlineMarkdownToText(source);
  return truncateMetadataDescription(
    plainText ? `cmux ${release.version}: ${plainText}` : `cmux ${release.version}`,
  );
}

function resolveChangelogPath(): string {
  const candidates = [
    path.resolve(process.cwd(), "..", "CHANGELOG.md"),
    path.resolve(process.cwd(), "CHANGELOG.md"),
  ];
  const changelog = candidates.find((candidate) => fs.existsSync(candidate));
  if (!changelog) {
    throw new Error(
      `CHANGELOG.md not found from ${process.cwd()}`,
    );
  }
  return changelog;
}

function inlineMarkdownToText(markdown: string): string {
  return markdown
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/[*_~]/g, "")
    .replace(/\s+--\s+thanks\b.*$/i, "")
    .replace(/\s+/g, " ")
    .trim();
}

function truncateMetadataDescription(
  description: string,
  maximumLength = 160,
): string {
  if (description.length <= maximumLength) return description;

  const candidate = description.slice(0, maximumLength - 1);
  const lastSpace = candidate.lastIndexOf(" ");
  const cutoff =
    lastSpace >= Math.floor(maximumLength * 0.7)
      ? lastSpace
      : candidate.length;
  return `${candidate.slice(0, cutoff).trimEnd()}…`;
}
