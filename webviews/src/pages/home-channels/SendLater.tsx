// Send Later's time picker (cmux#25634): a popover from the composer's Send Later control with a
// few presets (in 1 hour, in 3 hours, tomorrow morning, Monday morning), each with the time it
// means, and a date and time field for any other time. A pick resolves to Unix ms; the composer
// queues the message for then on the local owner (scheduled.ts). The same picker changes the time
// of a message already scheduled.
import { useState } from "react";
import { Popover, type UiAnchor } from "../../ui/Popover";
import type { Strings } from "../shared/i18n";

/** Where the composer puts Send Later: a clock button among its tools, or a segment on Send. */
export type SendLaterStyle = "clock" | "split";

const HOUR = 3_600_000;
/** The morning presets' hour (local time). */
const MORNING = 9;

/** The presets at `now`: each one's string key and time (ms). */
export function sendLaterPresets(now: Date): Array<{ key: string; at: number }> {
  const morning = (days: number) => {
    const day = new Date(now);
    day.setDate(day.getDate() + days);
    day.setHours(MORNING, 0, 0, 0);
    return day.getTime();
  };
  // Monday: the next one, a week ahead on a Monday.
  const toMonday = (8 - now.getDay()) % 7 || 7;
  return [
    { key: "sendLater.inOneHour", at: now.getTime() + HOUR },
    { key: "sendLater.inThreeHours", at: now.getTime() + 3 * HOUR },
    { key: "sendLater.tomorrow", at: morning(1) },
    ...(toMonday > 1 ? [{ key: "sendLater.monday", at: morning(toMonday) }] : []),
  ];
}

/** `at` as the person reads it: the time today, the weekday and time this week, else the date. */
export function sendLaterTime(at: number, now: Date, language: string): string {
  const when = new Date(at);
  const time: Intl.DateTimeFormatOptions = { hour: "numeric", minute: "2-digit" };
  const days = Math.round((startOfDay(when) - startOfDay(now)) / (24 * HOUR));
  const options: Intl.DateTimeFormatOptions =
    days === 0
      ? time
      : days > 0 && days < 7
        ? { ...time, weekday: "short" }
        : {
            ...time,
            month: "short",
            day: "numeric",
            ...(when.getFullYear() === now.getFullYear() ? {} : { year: "numeric" }),
          };
  return new Intl.DateTimeFormat(language, options).format(when);
}

const startOfDay = (date: Date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();

/** A `datetime-local` field's value for `at` (local time, minutes). */
function fieldValue(at: number): string {
  const date = new Date(at);
  const two = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())}T${two(date.getHours())}:${two(date.getMinutes())}`;
}

export interface SendLaterPickerProps {
  anchor: UiAnchor;
  strings: Strings;
  /** The time to start the date and time field at (a message being rescheduled). */
  initial?: number;
  /** The clock the presets count from (the gallery fixes it). */
  now?: () => Date;
  onPick(at: number): void;
  onClose(): void;
}

export function SendLaterPicker({
  anchor,
  strings,
  initial,
  now = () => new Date(),
  onPick,
  onClose,
}: SendLaterPickerProps) {
  const { t, language } = strings;
  const [opened] = useState(now);
  const [value, setValue] = useState(() => fieldValue(initial ?? opened.getTime() + HOUR));
  const custom = value ? new Date(value).getTime() : Number.NaN;
  const past = !Number.isFinite(custom) || custom <= now().getTime();
  return (
    <Popover
      open
      onOpenChange={(open) => !open && onClose()}
      anchor={anchor}
      side="top"
      label={t("sendLater.title")}
      className="hc-later"
      finalFocus={false}
    >
      <div className="hc-later-title">{t("sendLater.title")}</div>
      <ul className="hc-pick-list">
        {sendLaterPresets(opened).map((preset) => (
          <li key={preset.key}>
            <button type="button" className="hc-pick-row hc-later-row" onClick={() => onPick(preset.at)}>
              <span>{t(preset.key)}</span>
              <span className="hc-later-when">{sendLaterTime(preset.at, opened, language)}</span>
            </button>
          </li>
        ))}
      </ul>
      <form
        className="hc-later-custom"
        onSubmit={(event) => {
          event.preventDefault();
          if (!past) onPick(custom);
        }}
      >
        <input
          className="hc-link-field"
          type="datetime-local"
          value={value}
          min={fieldValue(opened.getTime())}
          aria-label={t("sendLater.custom")}
          onChange={(event) => setValue(event.target.value)}
        />
        <button type="submit" className="hc-text-button primary" disabled={past}>
          {t("sendLater.schedule")}
        </button>
      </form>
    </Popover>
  );
}
