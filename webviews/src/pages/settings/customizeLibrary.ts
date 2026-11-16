// Personalization > Customization Library (cmux-customize `library.rs`): what the card draws from
// `cmux customize library`'s listing. The engine owns the stack and its rule (where two entries that
// are on set the same key or file, the higher one wins); this only says it in words per entry.
import type { LibraryEntry, LibraryListing } from "./ops";
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
 * what it sets. */
export function entryDetail(entry: LibraryEntry): string {
  const what = entry.words[0] || entry.description || sourceLabel(entry.source);
  const keys = entry.thumbnail.keys.length > 0 ? entry.thumbnail.keys : [...entry.settings, ...entry.files];
  return keys.length > 0 ? `${what} · ${keys.join(", ")}` : what;
}

/** The sentence under an entry another one wins over: "Night is higher and wins: sidebar.width". */
export function beatenLine(beaten: Beaten): string {
  return t("settingsPage.customizeLibrary.beaten", beaten.winner, beaten.keys.join(", "));
}

/** Where Move Up and Move Down send an entry (`order NAME N`), or null at the edge. */
export function step(entry: LibraryEntry, count: number, by: -1 | 1): string | null {
  const to = entry.position + by;
  return to < 1 || to > count ? null : String(to);
}
