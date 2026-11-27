// Appearance > Customization Library (cmux-customize `library.rs`): what the card draws from
// `cmux customize library`'s listing. The engine owns the stack and its rule (where two entries that
// are on set the same key or file, the higher one wins); this only says it in words per entry.
import type { LibraryCode, LibraryEntry, LibraryListing } from "./ops";
import { t } from "./strings";

/** For one entry that is on: each higher entry that wins over it, with the keys it wins. */
export type Beaten = { winner: string; keys: string[] };

/** Every entry's `Beaten`, by name, from the listing's conflicts (winner first seen first). */
export function beatenByEntry(listing: LibraryListing): Map<string, Beaten[]> {
  const out = new Map<string, Beaten[]>();
  for (const conflict of listing.conflicts) {
    for (const loser of conflict.losers) {
      const list = out.get(loser) ?? [];
      const known = list.find((beaten) => beaten.winner === conflict.winner);
      if (known) known.keys.push(conflict.key);
      else list.push({ winner: conflict.winner, keys: [conflict.key] });
      out.set(loser, list);
    }
  }
  return out;
}

/** How an entry came in, in the page's words; a source this page does not know reads as is. */
export function sourceLabel(source: string): string {
  switch (source) {
    case "ask":
      return t("settingsPage.customizeLibrary.source.ask");
    case "profile":
      return t("settingsPage.customizeLibrary.source.profile");
    case "try-on":
      return t("settingsPage.customizeLibrary.source.tryOn");
    case "by hand":
      return t("settingsPage.customizeLibrary.source.byHand");
    case "import":
      return t("settingsPage.customizeLibrary.source.import");
    default:
      return source;
  }
}

/** The line under an entry's name: what asked for it (its first words, else how it came in), then
 * what it sets; for a PR entry, its repository and short head. */
export function entryDetail(entry: LibraryEntry): string {
  // A PR entry: where it comes from and the head it was built from (its own row adds the rest).
  if (entry.code) return `${entry.code.repo} · ${shortSha(entry.code.head)}`;
  const what = entry.words[0] || entry.description || sourceLabel(entry.source);
  const keys = entry.thumbnail.keys.length > 0 ? entry.thumbnail.keys : [...entry.settings, ...entry.files];
  return keys.length > 0 ? `${what} · ${keys.join(", ")}` : what;
}

/** The sentence under an entry another one wins over: "Night is higher and wins: sidebar.width". */
export function beatenLine(beaten: Beaten): string {
  // Two PRs that are on both serve pages (the stack key `code:web`): only the higher one's show.
  const keys = beaten.keys.filter((key) => key !== CODE_WEB_KEY);
  if (keys.length === 0) return t("settingsPage.customizeLibrary.code.beaten", beaten.winner);
  return t("settingsPage.customizeLibrary.beaten", beaten.winner, keys.join(", "));
}

/** The stack key of a PR entry's web part (cmux-customize `code::WEB_KEY`). */
export const CODE_WEB_KEY = "code:web";

/** Where Move Up and Move Down send an entry (`order NAME N`), or null at the edge. */
export function step(entry: LibraryEntry, count: number, by: -1 | 1): string | null {
  const to = entry.position + by;
  return to < 1 || to > count ? null : String(to);
}

/** The entry's pull request when it is a `pr-N` entry (`cmux customize use pr:N`), else null. */
export function codeOf(entry: LibraryEntry): LibraryCode | null {
  return entry.code ?? null;
}

/** The PR entries that are on: what the app's "N experiments on" mark counts. */
export function experimentsOn(listing: LibraryListing | null): LibraryEntry[] {
  return (listing?.entries ?? []).filter((entry) => entry.on && entry.code);
}

/** The PR's page on GitHub. */
export function prUrl(code: LibraryCode): string {
  return `https://github.com/${code.repo}/pull/${code.pr}`;
}

/** A commit as the page shows it: its first 7 characters. */
export function shortSha(sha: string): string {
  return sha.slice(0, 7);
}

/** The row's title: `#43543 Customize: use a PR` (the number alone while the title is unknown). */
export function codeTitle(code: LibraryCode): string {
  return code.title ? `#${code.pr} ${code.title}` : `#${code.pr}`;
}

/** Whether turning it on can apply anything: a PR with no web part has nothing a running app can
 * take (the CLI refuses `on`; its "needs a build" lines say why). */
export function codeCanTurnOn(code: LibraryCode): boolean {
  return Boolean(code.web);
}
