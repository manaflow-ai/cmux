// My scheduled messages in the open conversation (cmux#25634), above its composer: each row shows
// when it goes and the start of its text, with Edit (the text, in an inline composer), Change Time
// (the Send Later picker), Send Now and Cancel. A message the owner could not send at its time
// stays, marked Not sent, until I change, send or cancel it. Only my own messages are listed: the
// owner keeps every author's queue private.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { Composer } from "./Composer";
import { HomeIcon } from "./icons";
import { SendLaterPicker, sendLaterTime } from "./SendLater";
import type { ScheduledBook } from "./scheduled";
import type { HomeScheduled } from "./types";

export interface ScheduledStripProps {
  entries: readonly HomeScheduled[];
  book: ScheduledBook;
  strings: Strings;
  disabled?: boolean;
  /** The clock the times are read against (the gallery fixes it). */
  now?: () => Date;
}

export function ScheduledStrip({ entries, book, strings, disabled, now = () => new Date() }: ScheduledStripProps) {
  const { t, format, language } = strings;
  const [editing, setEditing] = useState<string | undefined>();
  const [picking, setPicking] = useState<{ entry: HomeScheduled; anchor: Element } | undefined>();
  if (entries.length === 0) return null;
  const today = now();
  return (
    <>
      <ul className="hc-scheduled" aria-label={t("scheduled.list")}>
        {entries.map((entry) => {
          const when = sendLaterTime(entry.sendAt, today, language);
          const failed = entry.state === "failed";
          if (editing === entry.id)
            return (
              <li key={entry.id}>
                <Composer
                  strings={strings}
                  placeholder={t("scheduled.edit")}
                  label={t("scheduled.edit")}
                  initialValue={entry.text}
                  focusOnOpen
                  onCancel={() => setEditing(undefined)}
                  onSend={async (text) => {
                    const saved = await book.edit(entry, text);
                    if (saved) setEditing(undefined);
                    return saved;
                  }}
                />
              </li>
            );
          return (
            <li key={entry.id} className={`hc-scheduled-row${failed ? " failed" : ""}`}>
              <HomeIcon name="clock" />
              <span className="hc-scheduled-when">{format(failed ? "scheduled.notSent" : "scheduled.at", when)}</span>
              <span className="hc-scheduled-text">
                {entry.text || format("scheduled.files", String(entry.attachments))}
              </span>
              {entry.text && (
                <button
                  type="button"
                  className="hc-text-button"
                  disabled={disabled}
                  onClick={() => setEditing(entry.id)}
                >
                  {t("scheduled.editText")}
                </button>
              )}
              <button
                type="button"
                className="hc-text-button"
                disabled={disabled}
                onClick={(event) => setPicking({ entry, anchor: event.currentTarget })}
              >
                {t("scheduled.changeTime")}
              </button>
              <button
                type="button"
                className="hc-text-button"
                disabled={disabled}
                onClick={() => void book.sendNow(entry)}
              >
                {t("scheduled.sendNow")}
              </button>
              <button
                type="button"
                className="hc-text-button"
                disabled={disabled}
                onClick={() => void book.cancel(entry)}
              >
                {t("scheduled.cancel")}
              </button>
            </li>
          );
        })}
      </ul>
      {picking && (
        <SendLaterPicker
          anchor={picking.anchor}
          strings={strings}
          initial={picking.entry.sendAt}
          now={now}
          onClose={() => setPicking(undefined)}
          onPick={(at) => {
            setPicking(undefined);
            void book.reschedule(picking.entry, at);
          }}
        />
      )}
    </>
  );
}
