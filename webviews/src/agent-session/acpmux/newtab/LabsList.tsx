// The Labs quick toggles of the New Tab page (hq#1980), in team builds only (nightly and dev): a
// quiet "Labs (N on)" that opens in place to the Labs flags, each a row with its name, its one-line
// intent, a New or Expires soon hint and a toggle, so the team tries prototypes where they start
// work. Open, the flags this viewer toggled last come first (kept in this page's storage), then
// the newest; the order is taken when the list opens, so a toggle never moves a row under the
// pointer. A toggle asks the app to save `labs.<flag>`; the row follows `data-labs`, the app's
// answer. All Labs… opens Settings > Labs, the full list.
import { useId, useState } from "react";
import {
  labsFlagTable,
  useLabsOn,
  useLabsTeamBuild,
  type LabsFlagInfo,
  type LabsFlagName,
} from "../../../experiments/labs";
import { useNt } from "./strings";

type Hint = "new" | "expiresSoon";

const DAY_MS = 86_400_000;
/** A flag reads as New for this long after its `created`, and Expires soon this long before its `expires`. */
const HINT_DAYS = 3;
const RECENT_KEY = "cmux.newTab.labs.recent";

function readRecent(): string[] {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage.getItem(RECENT_KEY) ?? "[]");
    return Array.isArray(value) ? value.filter((name): name is string => typeof name === "string") : [];
  } catch {
    return [];
  }
}

function noteRecent(name: string): void {
  try {
    const next = [name, ...readRecent().filter((other) => other !== name)].slice(0, 32);
    globalThis.localStorage.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    // No storage (a private window, blocked site data): the order stays the newest first.
  }
}

/** The rows' order: the flags toggled last first, then the newest `created`. */
function labsOrder(table: Readonly<Record<string, LabsFlagInfo>>): string[] {
  const recent = readRecent().filter((name) => name in table);
  const rest = Object.keys(table)
    .filter((name) => !recent.includes(name))
    .sort((a, b) => table[b]!.created.localeCompare(table[a]!.created) || a.localeCompare(b));
  return [...recent, ...rest];
}

function labsHint(flag: LabsFlagInfo, now: number): Hint | undefined {
  const expires = Date.parse(flag.expires);
  if (!Number.isNaN(expires) && expires - now <= HINT_DAYS * DAY_MS) return "expiresSoon";
  const created = Date.parse(flag.created);
  if (!Number.isNaN(created) && now - created <= HINT_DAYS * DAY_MS) return "new";
  return undefined;
}

type Props = {
  onSet: ((flag: LabsFlagName, on: boolean) => void) | undefined;
  onShowAll: (() => void) | undefined;
  now: number;
};

/** The Labs line and, open, its rows. Nothing outside a team build or without the app's handlers. */
export function LabsList({ onSet, onShowAll, now }: Props) {
  const nt = useNt();
  const team = useLabsTeamBuild();
  const onList = useLabsOn();
  const [order, setOrder] = useState<string[] | null>(null);
  const panelId = useId();
  if (!team || !onSet || !onShowAll) return null;
  const table = labsFlagTable();
  const on = new Set(onList.split(" ").filter((name) => name in table));
  const flip = () => setOrder(order ? null : labsOrder(table));
  return (
    <section className="nt-labs" aria-label={nt("labs")}>
      <div className="nt-labs-head">
        <button
          type="button"
          className="nt-labs-open"
          data-labs-open
          aria-expanded={order !== null}
          aria-controls={panelId}
          onClick={flip}
        >
          <span>{nt("labs.summary", { n: String(on.size) })}</span>
          <svg className="nt-labs-chevron" viewBox="0 0 16 16" width="10" height="10" aria-hidden="true">
            <path d="m6 4 4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          </svg>
        </button>
        {order && (
          <button type="button" className="nt-chats-all" data-show-labs onClick={onShowAll}>
            {nt("labs.all")}
          </button>
        )}
      </div>
      {order && (
        <div id={panelId} className="nt-labs-rows">
          {order.map((name) => {
            const flag = table[name];
            if (!flag) return null;
            const hint = labsHint(flag, now);
            const checked = on.has(name);
            return (
              <label key={name} className="nt-lab" data-lab={name} title={`labs.${name}`}>
                <span className="nt-lab-name">{flag.title}</span>
                <span className="nt-lab-intent">{flag.intent}</span>
                {hint && (
                  <span className="nt-lab-hint" data-lab-hint={hint}>
                    {nt(`labs.${hint}`)}
                  </span>
                )}
                <input
                  type="checkbox"
                  className="nt-lab-switch"
                  aria-label={flag.title}
                  checked={checked}
                  onChange={() => {
                    noteRecent(name);
                    onSet(name as LabsFlagName, !checked);
                  }}
                />
              </label>
            );
          })}
        </div>
      )}
    </section>
  );
}
