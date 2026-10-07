// What's New documents (decision WHATS-NEW-AFTER-UPDATE W2): the same
// whats-new/<version>.json files the app bundles, rendered at
// /whats-new/<version>. tools/sync-whats-new.ts copies the repository's
// whats-new/ into public/whats-new/ before the build, so the raw files are
// also served at /whats-new/<version>.json and /whats-new/media/...
// scripts/whats-new/validate.py is the full check; this loader only needs
// the shape and skips (with a build warning) any file it cannot read.

export type WhatsNewCategory = "new" | "improved" | "fixed" | "security";
export type WhatsNewChannel = "stable" | "rc" | "nightly";
export type WhatsNewText = Record<string, string>;

export type WhatsNewEntry = {
  id: string;
  category: WhatsNewCategory;
  title: WhatsNewText;
  summary: WhatsNewText;
  media?: { kind: "image" | "video"; light: string; dark: string; alt: WhatsNewText };
  tryIt?: { action?: string; deeplink?: string };
  docs?: string;
  platforms: string[];
  audience: "all" | "teams" | "enterprise";
};

export type WhatsNewDocument = {
  schemaVersion: 1;
  version: string;
  channel: WhatsNewChannel;
  date: string;
  headline: WhatsNewText;
  entries: WhatsNewEntry[];
};

export const whatsNewCategories: readonly WhatsNewCategory[] = ["new", "improved", "fixed", "security"];
export const whatsNewPath = "/whats-new";
export const whatsNewMediaBase = "/whats-new/";

const VERSION = /^(\d+)\.(\d+)\.(\d+)(?:-(rc|nightly)\.(\d+))?$/;

/** Version order: X.Y.Z numerically, then a prerelease before its release, then its number. */
export function compareWhatsNewVersions(a: string, b: string): number {
  const left = VERSION.exec(a);
  const right = VERSION.exec(b);
  if (!left || !right) return a.localeCompare(b);
  for (let index = 1; index <= 3; index++) {
    const difference = Number(left[index]) - Number(right[index]);
    if (difference !== 0) return difference;
  }
  if (!left[4] && !right[4]) return 0;
  if (!left[4]) return 1;
  if (!right[4]) return -1;
  const difference = Number(left[5]) - Number(right[5]);
  return difference !== 0 ? difference : left[4].localeCompare(right[4]);
}

/** The document language for a site locale (the app uses Apple language codes). */
export function documentLanguage(siteLocale: string): string {
  switch (siteLocale) {
    case "no":
      return "nb";
    case "zh-CN":
      return "zh-Hans";
    case "zh-TW":
      return "zh-Hant";
    default:
      return siteLocale;
  }
}

/** The text for the page's locale, else English. */
export function localizedText(text: WhatsNewText | undefined, siteLocale: string): string {
  if (!text) return "";
  return text[documentLanguage(siteLocale)] || text.en || "";
}

/** A deeplink the web can open; a registry action id has no web meaning. */
export function webTryItLink(entry: WhatsNewEntry): string | undefined {
  const link = entry.tryIt?.deeplink;
  return link && link.startsWith("cmux://") ? link : undefined;
}

function isText(value: unknown): value is WhatsNewText {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as WhatsNewText).en === "string" &&
    Object.values(value).every((text) => typeof text === "string")
  );
}

function isSafeMediaPath(path: unknown): path is string {
  return typeof path === "string" && /^media\/[A-Za-z0-9._/-]+$/.test(path) && !path.split("/").includes("..");
}

function isEntry(value: unknown): value is WhatsNewEntry {
  if (typeof value !== "object" || value === null) return false;
  const entry = value as WhatsNewEntry;
  const media = entry.media;
  return (
    typeof entry.id === "string" &&
    whatsNewCategories.includes(entry.category) &&
    isText(entry.title) &&
    isText(entry.summary) &&
    Array.isArray(entry.platforms) &&
    (media === undefined || (isSafeMediaPath(media.light) && isSafeMediaPath(media.dark) && isText(media.alt))) &&
    (entry.docs === undefined || (typeof entry.docs === "string" && entry.docs.startsWith("https://")))
  );
}

/** Parses one file; undefined (with the reason) when it is not a readable document for `fileVersion`. */
export function parseWhatsNewDocument(
  text: string,
  fileVersion: string,
): { document?: WhatsNewDocument; problem?: string } {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (error) {
    return { problem: `unreadable JSON (${(error as Error).message})` };
  }
  const document = value as WhatsNewDocument;
  if (typeof value !== "object" || value === null || document.schemaVersion !== 1) {
    return { problem: "schemaVersion must be 1" };
  }
  if (typeof document.version !== "string" || !VERSION.test(document.version) || document.version !== fileVersion) {
    return { problem: `version must be ${fileVersion}` };
  }
  if (!["stable", "rc", "nightly"].includes(document.channel) || typeof document.date !== "string" || !isText(document.headline)) {
    return { problem: "channel, date or headline is invalid" };
  }
  if (!Array.isArray(document.entries) || !document.entries.every(isEntry)) {
    return { problem: "an entry is invalid" };
  }
  return { document };
}

/** A set of documents, newest first. */
export class WhatsNewStore {
  readonly documents: WhatsNewDocument[];

  constructor(files: { name: string; text: string }[], warn: (message: string) => void = console.warn) {
    const documents: WhatsNewDocument[] = [];
    for (const file of files) {
      if (!file.name.endsWith(".json")) continue;
      const version = file.name.slice(0, -".json".length);
      const { document, problem } = parseWhatsNewDocument(file.text, version);
      if (document) {
        documents.push(document);
      } else {
        warn(`whats-new: skipped ${file.name}: ${problem}`);
      }
    }
    this.documents = documents.sort((a, b) => compareWhatsNewVersions(b.version, a.version));
  }

  find(version: string): WhatsNewDocument | undefined {
    return this.documents.find((document) => document.version === version);
  }

  /** The newer and older documents around `version`. */
  neighbors(version: string): { newer?: WhatsNewDocument; older?: WhatsNewDocument } {
    const index = this.documents.findIndex((document) => document.version === version);
    if (index < 0) return {};
    return { newer: this.documents[index - 1], older: this.documents[index + 1] };
  }
}

export function localizedWhatsNewPath(locale: string, version?: string): string {
  const path = version ? `${whatsNewPath}/${version}` : whatsNewPath;
  return locale === "en" ? path : `/${locale}${path}`;
}
