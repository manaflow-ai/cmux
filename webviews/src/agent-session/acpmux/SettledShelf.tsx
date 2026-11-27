// The home's Settled shelf (settledChats.ts): the chats acpmux settled, collapsed to one "Settled N"
// row by default, since they are done. Opened, each row opens its chat the way a Home row does. A
// chat the pane holds also has Unsettle, which puts it back on every list; any other has none, since
// the app relays Unarchive only for a chat in the pane's scope (settledToasts.ts), and opening it
// brings it in.
import { useState } from "react";
import { Button } from "../../ui/Button";
import { Tooltip } from "../../ui/Tooltip";
import { pressToOpen } from "../../ui/pressToOpen";
import { useT } from "./i18n";
import { age } from "./homeListsModel";
import { settleReasonText } from "./settledChats";
import { activityTime, type AcpmuxSessionEntry } from "./sessionList";

export function SettledShelf({
  rows,
  total,
  onSelect,
  onUnsettle,
  holds,
  open: initiallyOpen = false,
}: {
  /** The settled chats it lists, newest first (settledShelf). */
  rows: readonly AcpmuxSessionEntry[];
  /** How many chats are settled, also past the rows it lists. */
  total: number;
  onSelect: (sessionId: string) => void;
  onUnsettle: (entry: AcpmuxSessionEntry) => void;
  /** Whether the pane holds a chat: only those rows have Unsettle. */
  holds: (entry: AcpmuxSessionEntry) => boolean;
  /** Opened at first (the gallery); the home starts it collapsed. */
  open?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(initiallyOpen);
  // The ages are read as of when the shelf opened: a render reads no clock.
  const [now, setNow] = useState(() => Date.now());
  if (total === 0) return null;
  const label = t("settle.shelf");
  return (
    <section className="acpmux-home-list acpmux-settled-shelf" aria-label={label} data-open={open ? "" : undefined}>
      <Button
        bare
        type="button"
        className="acpmux-home-row acpmux-settled-toggle"
        aria-expanded={open}
        onClick={() => {
          setNow(Date.now());
          setOpen((shown) => !shown);
        }}
      >
        <ShelfChevron open={open} />
        <span className="acpmux-settled-label">{label}</span>
        <span className="acpmux-home-inbox-count">{total}</span>
      </Button>
      {open && (
        <ul>
          {rows.map((entry) => (
            <SettledRow
              key={`${entry.peer ?? ""}:${entry.sessionId}`}
              entry={entry}
              now={now}
              onSelect={onSelect}
              onUnsettle={holds(entry) ? onUnsettle : undefined}
            />
          ))}
        </ul>
      )}
    </section>
  );
}

function SettledRow({
  entry,
  now,
  onSelect,
  onUnsettle,
}: {
  entry: AcpmuxSessionEntry;
  now: number;
  onSelect: (sessionId: string) => void;
  onUnsettle?: (entry: AcpmuxSessionEntry) => void;
}) {
  const t = useT();
  const title = entry.displayTitle ?? entry.title ?? entry.name ?? entry.sessionId;
  const reason = settleReasonText(entry, now, t);
  const when = age(activityTime(entry), now, t);
  return (
    <li className="acpmux-settled-row">
      <Button bare type="button" className="acpmux-home-row" {...pressToOpen(() => onSelect(entry.sessionId))}>
        <Tooltip label={title}>
          <span className="acpmux-home-title">{title}</span>
        </Tooltip>
        {reason && (
          <Tooltip label={reason}>
            <span className="acpmux-home-detail">{reason}</span>
          </Tooltip>
        )}
        {when && <span className="acpmux-home-meta">{when}</span>}
      </Button>
      {onUnsettle && (
        <Button variant="ghost" size="sm" className="acpmux-settled-unsettle" onClick={() => onUnsettle(entry)}>
          {t("settle.unsettle")}
        </Button>
      )}
    </li>
  );
}

const ShelfChevron = ({ open }: { open: boolean }) => (
  <svg
    className="acpmux-icon"
    width={16}
    height={16}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.25}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    <path d={open ? "m4.25 6.25 3.75 3.5 3.75-3.5" : "m6.25 4.25 3.5 3.75-3.5 3.75"} />
  </svg>
);
