// l10n-allow-file: gallery-first (RFD 0123). The copy moves to the Settings catalog in all languages
// when the card is wired into Settings > Accounts.
import { Button } from "../../../ui/Button";
import { Select } from "../../../ui/Select";
import { ALLOWANCE_PRESETS, awakeDuration, spentToday, type SlackAwake, type SlackNames } from "../slackAwake";

export interface SlackAwakeCardProps {
  awake: SlackAwake;
  /** UTC day the "who spent" list reads, `YYYY-MM-DD`. */
  today: string;
  names?: SlackNames;
  busy?: boolean;
  /** `PUT /v1/chiefs/<agent>/slack-awake`: seconds, or null for the default. */
  setAllowance(seconds: number | null): void;
}

/**
 * The owner's half of RFD 0123's meter: how long a non-owner may keep the Chief awake each day, and
 * who spent today's time. The allowance is a preset Select (picked over a stepper and a slider on
 * cmux#57819: one tap, no typing, and it matches the other Settings selects).
 */
export function SlackAwakeCard({ awake, today, names, busy = false, setAllowance }: SlackAwakeCardProps) {
  const rows = spentToday(awake, today, names);
  const isDefault = awake.allowance_seconds === awake.default_seconds;
  const options = ALLOWANCE_PRESETS.filter((s) => s <= awake.max_seconds).map((s) => ({
    value: String(s),
    label: s === 0 ? "Never" : awakeDuration(s),
  }));
  if (!options.some((o) => o.value === String(awake.allowance_seconds))) {
    options.push({ value: String(awake.allowance_seconds), label: awakeDuration(awake.allowance_seconds) });
    options.sort((a, b) => Number(a.value) - Number(b.value));
  }
  return (
    <section className="group" data-card="slack-awake" aria-busy={busy}>
      <h3 className="group-title">Slack awake time</h3>
      <div className="rows">
        <div className="row">
          <div className="row-label">
            <span className="row-title">Each teammate, per day</span>
            <span className="row-help">
              {awake.allowance_seconds === 0
                ? "Only you can wake your Chief from Slack."
                : `Others can keep your Chief awake ${awakeDuration(awake.allowance_seconds)} a day. Your own messages are never capped.`}
            </span>
          </div>
          <Select
            label="Awake time per teammate"
            value={String(awake.allowance_seconds)}
            options={options}
            disabled={busy}
            closeOnPick
            align="end"
            onChange={(value) => setAllowance(Number(value))}
          />
        </div>
        {!isDefault && (
          <div className="row">
            <span className="row-help">Default is {awakeDuration(awake.default_seconds)}.</span>
            <Button
              className="link-button"
              variant="ghost"
              size="sm"
              disabled={busy}
              onClick={() => setAllowance(null)}
            >
              Use default
            </Button>
          </div>
        )}
        <div className="row" data-slack-awake="spent">
          <div className="row-label">
            <span className="row-title">Who spent it today</span>
            {rows.length === 0 && <span className="row-help">Nobody has woken your Chief from Slack today.</span>}
          </div>
        </div>
        {rows.map((row) => (
          <div className="row" key={row.user} data-slack-awake-sender={row.user}>
            <div className="row-label">
              <span className="row-title">
                {row.name}
                {row.owner ? " (you)" : ""}
              </span>
              <span className="row-help">
                {row.turns === 1 ? "1 message" : `${row.turns} messages`}
                {row.used === 1 && !row.owner ? " · out for today" : ""}
              </span>
            </div>
            <output className="row-value">
              {row.used !== null
                ? `${awakeDuration(row.seconds)} / ${awakeDuration(awake.allowance_seconds)}`
                : awakeDuration(row.seconds)}
            </output>
          </div>
        ))}
      </div>
    </section>
  );
}
