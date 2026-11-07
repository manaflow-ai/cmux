// Fixes a mistyped top-level domain in typed text (`example.con` loads `example.com`), with
// Firefox's table (HostTypoFixup.swift). Only the host's last label changes. Apply it only to
// typed text: never to pasted text, links, bookmarks, history rows or agent input.

/** Mistyped last label -> intended top-level domain. */
export const HOST_TYPOS: Readonly<Record<string, string>> = {
  ocm: "com",
  con: "com",
  cmo: "com",
  xom: "com",
  vom: "com",
  cpm: "com",
  "com'": "com",
  ent: "net",
  ner: "net",
  nte: "net",
  met: "net",
  rog: "org",
  ogr: "org",
  prg: "org",
  orh: "org",
};

export interface HostTypoFix {
  /** The typed text with the last host label replaced. */
  text: string;
  /** The host as typed, lowercased. */
  typedHost: string;
}

/**
 * The fixed text, or null when `text` has nothing to fix. `isTopLevelDomain` checks the IANA root
 * zone; no label of the table is delegated today, so the default says no.
 */
export function fixHostTypo(
  text: string,
  isTopLevelDomain: (label: string) => boolean = () => false,
): HostTypoFix | null {
  const trimmed = text.trim();
  if (!trimmed || /\s/.test(trimmed)) return null;
  let authorityStart = 0;
  const separator = trimmed.indexOf("://");
  if (separator >= 0) {
    const scheme = trimmed.slice(0, separator).toLowerCase();
    if (scheme !== "http" && scheme !== "https") return null;
    authorityStart = separator + 3;
  }
  const rest = trimmed.slice(authorityStart);
  const end = rest.search(/[/?#]/);
  const authority = end < 0 ? rest : rest.slice(0, end);
  if (!authority || authority.includes("@") || authority.startsWith("[")) return null;
  let hostEnd = authority.length;
  const colon = authority.indexOf(":");
  if (colon >= 0) {
    if (!/^[0-9]+$/.test(authority.slice(colon + 1))) return null;
    hostEnd = colon;
  }
  const host = authority.slice(0, hostEnd);
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((label) => !label)) return null;
  const last = labels[labels.length - 1];
  const typedLabel = last.toLowerCase();
  const intended = Object.hasOwn(HOST_TYPOS, typedLabel) ? HOST_TYPOS[typedLabel] : undefined;
  if (!intended || isTopLevelDomain(typedLabel)) return null;
  const labelStart = authorityStart + hostEnd - last.length;
  return {
    text: trimmed.slice(0, labelStart) + intended + trimmed.slice(labelStart + last.length),
    typedHost: host.toLowerCase(),
  };
}

/** Typed hosts the omnibar already fixed: typing one again loads it as typed. */
export class HostTypoMemory {
  private readonly fixed = new Set<string>();

  allowsFix(typedHost: string): boolean {
    return !this.fixed.has(typedHost.toLowerCase());
  }

  recordFix(typedHost: string): void {
    this.fixed.add(typedHost.toLowerCase());
  }
}
