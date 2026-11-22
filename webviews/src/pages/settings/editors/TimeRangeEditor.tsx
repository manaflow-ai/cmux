import { useState } from "react";
import { useStore } from "../context";
import { t } from "../strings";
import { isTime } from "../validate";
import type { EditorProps } from "./types";

type Range = { start: string; end: string };

/** Two time fields; the range is written once both hold a valid time. */
export function TimeRangeEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const stored = (value && typeof value === "object" ? value : { start: "", end: "" }) as Range;
  const [draft, setDraft] = useState<Range | null>(null);
  const shown = draft ?? stored;
  const change = (next: Range) => {
    if (isTime(next.start) && isTime(next.end)) {
      setDraft(null);
      if (next.start !== stored.start || next.end !== stored.end) void store.set(row.key, next);
    } else setDraft(next);
  };
  return (
    <fieldset className="time-range" aria-labelledby={labelId}>
      <input
        className="field time"
        type="time"
        value={shown.start}
        disabled={disabled}
        aria-label={t("settingsPage.quietFrom")}
        onChange={(event) => change({ ...shown, start: event.currentTarget.value })}
      />
      <span className="time-separator">–</span>
      <input
        className="field time"
        type="time"
        value={shown.end}
        disabled={disabled}
        aria-label={t("settingsPage.quietTo")}
        onChange={(event) => change({ ...shown, end: event.currentTarget.value })}
      />
    </fieldset>
  );
}
