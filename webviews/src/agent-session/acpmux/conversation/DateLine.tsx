// The timestamp line over a turn (conversation/timestamps.ts), centered and quiet:
// "Sun, Sep 13 at 7:55 PM", "Yesterday 8:16 PM". English, like the rest of the pane's
// transcript words, so the date and its " at " read as one language.
import type { AcpmuxRow } from "../model";
import { hasTimestamp, timestampText } from "./timestamps";

export function DateLine({ row, now = Date.now() }: { row: AcpmuxRow; now?: number }) {
  if (!hasTimestamp(row.at)) return null;
  return (
    <time className="cv-date-line" dateTime={new Date(row.at).toISOString()}>
      {timestampText(row.at, { now, locale: "en-US" })}
    </time>
  );
}
