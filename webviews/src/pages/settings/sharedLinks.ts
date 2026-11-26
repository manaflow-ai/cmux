// Settings > Privacy and Security > Shared Links (design chat-multiplayer.md 2, "Shared links"): the
// rows the card draws from this Mac's daemon's shares (`cmux.settings.shares.list`). The daemon keeps
// ended shares for a while (revoked, expired, closed); the card lists only the ones that still let
// someone in, newest first, like ChatGPT's Settings > Data controls > Shared links.
import type { SharesState, ShareWire } from "./ops";
import { intl } from "../../ui/intl";

/** One shared chat's row. */
export type SharedLinkRow = {
  id: string;
  /** The chat's tab title; null when no tab shows the chat (the card says "Untitled chat"). */
  chat: string | null;
  /** `link`: a guest link only. `people`: cmux accounts are invited (`invited` of them). */
  kind: "link" | "people";
  invited: number;
  createdAt: number;
  expiresAt: number;
  /** The names of the guests in the chat now. */
  guests: string[];
};

/** A share still lets someone in: it is live and has not run out. */
export function shareIsLive(share: ShareWire, now: number): boolean {
  return (share.state === "active" || share.state === "provisioning") && share.expires_at > now;
}

/** The card's rows: live shares, newest first (ties by id, so the order never flickers). */
export function sharedLinkRows(state: SharesState | null | undefined, now: number): SharedLinkRow[] {
  if (!state?.available) return [];
  const titles = state.titles ?? {};
  return (state.shares ?? [])
    .filter((share) => shareIsLive(share, now))
    .map((share): SharedLinkRow => {
      const invited = (share.invitees ?? []).filter((invitee) => invitee.state === "invited").length;
      const title = titles[String(share.surface)]?.trim();
      return {
        id: share.share_id,
        chat: title ? title : null,
        kind: invited > 0 ? "people" : "link",
        invited,
        createdAt: share.created_at,
        expiresAt: share.expires_at,
        guests: share.guests.filter((guest) => guest.state === "active").map((guest) => guest.account ?? guest.name),
      };
    })
    .sort((a, b) => b.createdAt - a.createdAt || a.id.localeCompare(b.id));
}

/** `next` with each row equal to the one `previous` had for its id replaced by that one, so a memo
 * row whose share did not change skips a new read of the list. */
export function keepUnchangedLinks(previous: readonly SharedLinkRow[], next: SharedLinkRow[]): SharedLinkRow[] {
  const held = new Map(previous.map((row) => [row.id, row]));
  return next.map((row) => {
    const old = held.get(row.id);
    return old && sameLink(old, row) ? old : row;
  });
}

function sameLink(a: SharedLinkRow, b: SharedLinkRow): boolean {
  return (
    a.chat === b.chat &&
    a.kind === b.kind &&
    a.invited === b.invited &&
    a.createdAt === b.createdAt &&
    a.expiresAt === b.expiresAt &&
    a.guests.length === b.guests.length &&
    a.guests.every((guest, index) => guest === b.guests[index])
  );
}

/** The start of `now`'s day: all a row's dates need of the clock (shareDate only asks whether a
 * date is today), so the rows draw again once a day, not on every read of the clock. */
export function startOfDay(now: number): number {
  const day = new Date(now);
  day.setHours(0, 0, 0, 0);
  return day.getTime();
}

/** A row's date in the page's locale: the day, and the time when it is today. */
export function shareDate(at: number, now: number, locale: string): string {
  const date = new Date(at);
  const sameDay = new Date(now).toDateString() === date.toDateString();
  const format = sameDay
    ? intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" })
    : intl.DateTimeFormat(locale, { month: "short", day: "numeric" });
  return format.format(date);
}
