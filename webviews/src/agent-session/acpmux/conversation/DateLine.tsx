// The timestamp line over a turn, centered and quiet, in the pane's live language.
import { usePaneLanguage } from "../i18n";
import type { AcpmuxRow } from "../model";
import { hasTimestamp, timestampText } from "./timestamps";

export function DateLine({ row, now = Date.now() }: { row: AcpmuxRow; now?: number }) {
  const language = usePaneLanguage();
  if (!hasTimestamp(row.at)) return null;
  return (
    <time className="cv-date-line" dateTime={new Date(row.at).toISOString()}>
      {timestampText(row.at, { now, locale: language })}
    </time>
  );
}
