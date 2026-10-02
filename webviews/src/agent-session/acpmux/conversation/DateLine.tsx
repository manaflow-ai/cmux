// The date over the first prompt of a day, centered and quiet: "Sun, Sep 13 at 7:55 PM", with
// the year when it is not this one.
import type { AcpmuxRow } from "../model";

const day = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric" });
const dayAndYear = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  month: "short",
  day: "numeric",
  year: "numeric",
});
const time = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

export function dateLabel(at: number, now = Date.now()): string {
  const sameYear = new Date(at).getFullYear() === new Date(now).getFullYear();
  return `${(sameYear ? day : dayAndYear).format(at)} at ${time.format(at)}`;
}

export function DateLine({ row }: { row: AcpmuxRow }) {
  return (
    <time className="cv-date-line" dateTime={new Date(row.at).toISOString()}>
      {dateLabel(row.at)}
    </time>
  );
}
