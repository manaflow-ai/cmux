// The Stashed Tabs page's pure presentation: OneTab text parsing, search over the groups, and the
// row texts. No IO; the store (store.ts) owns state and intents. Bun tests drive it directly.
import type { StashGroup, StashImportGroup, StashImportTab, StashMember, StashRecord } from "./types";

/** Most tabs one imported group takes (`stash.import`); a longer group is split. */
export const MAX_IMPORT_TABS = 1000;
/** Most groups one import takes; the rest are dropped. */
export const MAX_IMPORT_GROUPS = 1000;
const MAX_URL_BYTES = 8192;
const MAX_TITLE_BYTES = 1024;

const utf8 = new TextEncoder();

/** `title` cut on a code point boundary to `max` UTF-8 bytes (the daemon refuses longer ones). */
function capped(title: string, max = MAX_TITLE_BYTES): string {
  if (utf8.encode(title).length <= max) return title;
  let bytes = 0;
  let out = "";
  for (const char of title) {
    bytes += utf8.encode(char).length;
    if (bytes > max) break;
    out += char;
  }
  return out;
}

function tab(line: string): StashImportTab | undefined {
  // `url | ` (an empty title) lost its space to the line trim.
  const text = line.endsWith(" |") ? `${line} ` : line;
  const split = text.indexOf(" | ");
  const url = (split < 0 ? text : text.slice(0, split)).trim();
  if (!url || utf8.encode(url).length > MAX_URL_BYTES) return undefined;
  const title = split < 0 ? "" : capped(text.slice(split + 3).trim());
  return title ? { url, title } : { url };
}

/** OneTab's "Export URLs" text: one `url | title` line per tab, groups separated by blank lines. A
 * line without ` | ` is a bare address. Every non-empty line is kept (the daemon keeps only
 * http(s) pages); sizes are capped to what `stash.import` accepts. */
export function parseOneTab(text: string): StashImportGroup[] {
  const groups: StashImportGroup[] = [];
  let current: StashImportTab[] = [];
  const close = () => {
    for (let start = 0; start < current.length; start += MAX_IMPORT_TABS)
      groups.push({ tabs: current.slice(start, start + MAX_IMPORT_TABS) });
    current = [];
  };
  for (const raw of text.split(/\r\n|\r|\n/)) {
    const line = raw.trim();
    if (!line) {
      close();
      continue;
    }
    const parsed = tab(line);
    if (parsed) current.push(parsed);
  }
  close();
  return groups.slice(0, MAX_IMPORT_GROUPS);
}

/** A `stash.list` record with its time as a number (`cmux.protocol/2` sends decimals as strings). */
export function normalized(record: StashRecord): StashGroup {
  return { ...record, created_at_ms: Number(record.created_at_ms) };
}

/** Case, diacritic and width insensitive, as the Swift page's `localizedStandardContains`. */
export function fold(text: string): string {
  return text.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase();
}

export function isWorkspace(member: StashMember): boolean {
  return member.kind === "workspace";
}

/** A workspace's tab titles (else its pages' addresses); none for a page. */
export function workspaceTabs(member: StashMember): string[] {
  if (!isWorkspace(member)) return [];
  return (member.tabs ?? []).flatMap((tab) => (tab.title ? [tab.title] : tab.url ? [tab.url] : []));
}

/** The row's title: the page title, else its address; a workspace's name, else `untitled`. */
export function memberTitle(member: StashMember, untitledWorkspace: string): string {
  if (isWorkspace(member)) return member.name || member.title || untitledWorkspace;
  return member.title || member.url || "";
}

/** A page's host, shown after its title; nil for a workspace or an address without one. */
export function memberHost(member: StashMember): string | undefined {
  if (isWorkspace(member) || !member.url) return undefined;
  try {
    return new URL(member.url).host || undefined;
  } catch {
    return undefined;
  }
}

function memberTexts(member: StashMember): string[] {
  const texts = [member.title, member.url, member.name];
  for (const tab of member.tabs ?? []) texts.push(tab.title, tab.url);
  return texts.filter((text): text is string => !!text);
}

/** The groups whose members match `query`: a page's title or address, a workspace's name, tab
 * title or address, or the group's name (which keeps all its members). Every group for a blank
 * query. */
export function matchGroups(groups: readonly StashGroup[], query: string): StashGroup[] {
  const needle = fold(query.trim());
  if (!needle) return [...groups];
  const matches = (text: string | undefined) => !!text && fold(text).includes(needle);
  return groups.flatMap((group) => {
    if (matches(group.name)) return [group];
    const members = group.members.filter((member) => memberTexts(member).some(matches));
    return members.length ? [{ ...group, members }] : [];
  });
}

/** Members hidden while their delete waits on the app's Undo toast (`hidden` holds stash ids and
 * `stash/member` keys); groups left with no member drop out. */
export function visibleGroups(groups: readonly StashGroup[], hidden: ReadonlySet<string>): StashGroup[] {
  if (hidden.size === 0) return [...groups];
  return groups.flatMap((group) => {
    if (hidden.has(group.id)) return [];
    const members = group.members.filter((member) => !hidden.has(memberKey(group.id, member.id)));
    return members.length ? [{ ...group, members }] : [];
  });
}

export function memberKey(stash: string, member: string): string {
  return `${stash}/${member}`;
}

/** Every member of every group. */
export function memberCount(groups: readonly StashGroup[]): number {
  return groups.reduce((sum, group) => sum + group.members.length, 0);
}
