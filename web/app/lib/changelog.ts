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

// Keep the newest releases ready at deploy time. Cache Components resolves
// omitted versions at request time, so historical URLs stay available without
// making every locale/version combination part of every deployment.
export const changelogStaticVersionCount = 12;

export interface ChangelogVersionEntry {
  release: ChangelogVersion;
  index: number;
}

export interface ChangelogVersionContext extends ChangelogVersionEntry {
  versions: readonly ChangelogVersion[];
}

export interface ChangelogSource {
  fingerprint(): string;
  read(): string;
}

/** Returns the releases that should be prerendered during a deployment. */
export function changelogVersionsForPrerender(
  versions: readonly ChangelogVersion[],
): readonly ChangelogVersion[] {
  return versions.slice(0, changelogStaticVersionCount);
}

interface ChangelogSnapshot {
  fingerprint: string;
  versions: readonly ChangelogVersion[];
  entries: ReadonlyMap<string, ChangelogVersionEntry>;
}

export class ChangelogStore {
  private snapshot: ChangelogSnapshot | undefined;

  constructor(private readonly source: ChangelogSource) {}

  /** Returns the current ordered release list. */
  versions(): readonly ChangelogVersion[] {
    return this.readSnapshot().versions;
  }

  /** Looks up one release by its version number. */
  findVersion(version: string): ChangelogVersion | undefined {
    return this.readSnapshot().entries.get(version)?.release;
  }

  /** Looks up one release together with its adjacent-release source list. */
  findVersionContext(version: string): ChangelogVersionContext | undefined {
    const snapshot = this.readSnapshot();
    const entry = snapshot.entries.get(version);
    return entry ? { ...entry, versions: snapshot.versions } : undefined;
  }

  private readSnapshot(): ChangelogSnapshot {
    const fingerprint = this.source.fingerprint();
    if (this.snapshot?.fingerprint === fingerprint) {
      return this.snapshot;
    }

    const versions = parseChangelog(this.source.read());
    this.snapshot = {
      fingerprint,
      versions,
      entries: new Map(
        versions.map((release, index) => [
          release.version,
          { release, index },
        ]),
      ),
    };
    return this.snapshot;
  }
}

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
