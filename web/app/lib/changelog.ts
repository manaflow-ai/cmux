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

export interface ChangelogVersionEntry {
  release: ChangelogVersion;
  index: number;
}

export interface ChangelogVersionContext extends ChangelogVersionEntry {
  versions: readonly ChangelogVersion[];
}

interface ChangelogSnapshot {
  path: string;
  modifiedAt: number;
  changedAt: number;
  size: number;
  versions: readonly ChangelogVersion[];
  entries: ReadonlyMap<string, ChangelogVersionEntry>;
}

let cachedChangelog: ChangelogSnapshot | undefined;

/** Parses the repository changelog into ordered release records. */
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

/** Returns the current changelog, refreshing the cache when its source changes. */
export function readChangelog(): readonly ChangelogVersion[] {
  return readChangelogSnapshot().versions;
}

/** Looks up one release together with its adjacent-release source list. */
export function findChangelogVersionContext(
  version: string,
): ChangelogVersionContext | undefined {
  const snapshot = readChangelogSnapshot();
  const entry = snapshot.entries.get(version);
  return entry ? { ...entry, versions: snapshot.versions } : undefined;
}

/** Looks up one release by its version number. */
export function findChangelogVersion(
  version: string,
): ChangelogVersion | undefined {
  return readChangelogSnapshot().entries.get(version)?.release;
}

/** Returns the canonical path for one changelog release. */
export function changelogVersionPath(version: string): string {
  return `${changelogPath}/${encodeURIComponent(version)}`;
}

/** Returns the locale-prefixed path for the changelog or one release. */
export function localizedChangelogPath(
  locale: string,
  version?: string,
): string {
  const releasePath = version ? changelogVersionPath(version) : changelogPath;
  return locale === "en" ? releasePath : `/${locale}${releasePath}`;
}

/** Builds a bounded English search summary from one release. */
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

function readChangelogSnapshot(): ChangelogSnapshot {
  const changelog = resolveChangelogPath();
  const stats = fs.statSync(changelog);
  if (
    cachedChangelog?.path === changelog &&
    cachedChangelog.modifiedAt === stats.mtimeMs &&
    cachedChangelog.changedAt === stats.ctimeMs &&
    cachedChangelog.size === stats.size
  ) {
    return cachedChangelog;
  }

  const versions = parseChangelog(fs.readFileSync(changelog, "utf-8"));
  cachedChangelog = {
    path: changelog,
    modifiedAt: stats.mtimeMs,
    changedAt: stats.ctimeMs,
    size: stats.size,
    versions,
    entries: new Map(
      versions.map((release, index) => [
        release.version,
        { release, index },
      ]),
    ),
  };
  return cachedChangelog;
}

function resolveChangelogPath(): string {
  const candidates = [
    path.resolve(process.cwd(), "..", "CHANGELOG.md"),
    path.resolve(process.cwd(), "CHANGELOG.md"),
  ];
  const changelog = candidates.find((candidate) => fs.existsSync(candidate));
  if (!changelog) {
    throw new Error("Changelog unavailable");
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
