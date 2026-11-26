// l10n-allow-file: gallery-first (RFD 0123). The picked variant's copy moves to the Settings catalog
// in all languages before it is wired into Settings > Accounts.
import { useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Select } from "../../../ui/Select";
import { ALLOWANCE_PRESETS, awakeDuration, spentToday, type SlackAwake, type SlackNames } from "../slackAwake";

/** How the card asks for the allowance; the gallery shows each so one can be picked. */
export type SlackAwakeLook = "stepper" | "presets" | "slider";

export interface SlackAwakeCardProps {
  awake: SlackAwake;
  /** UTC day the "who spent" list reads, `YYYY-MM-DD`. */
  today: string;
  names?: SlackNames;
  look: SlackAwakeLook;
  busy?: boolean;
  /** `PUT /v1/chiefs/<agent>/slack-awake`: seconds, or null for the default. */
  setAllowance(seconds: number | null): void;
}

const HOUR = 3600;

/** The owner's half of RFD 0123's meter: how long a non-owner may keep the Chief awake each day, and who spent today's time. */
export function SlackAwakeCard({ awake, today, names, look, busy = false, setAllowance }: SlackAwakeCardProps) {
  const rows = spentToday(awake, today, names);
  const isDefault = awake.allowance_seconds === awake.default_seconds;
  return (
    <section className="group" data-card="slack-awake" data-look={look} aria-busy={busy}>
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
          <AllowanceControl look={look} awake={awake} busy={busy} setAllowance={setAllowance} />
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
            {look === "stepper" && row.used !== null ? (
              <meter
                className="slack-awake-meter"
                min={0}
                max={1}
                value={row.used}
                aria-label={`${row.name}: ${awakeDuration(row.seconds)} of ${awakeDuration(awake.allowance_seconds)}`}
              />
            ) : null}
            <output className="row-value">
              {look === "slider" && row.used !== null
                ? `${awakeDuration(Math.max(awake.allowance_seconds - row.seconds, 0))} left`
                : look === "presets" && row.used !== null
                  ? `${awakeDuration(row.seconds)} / ${awakeDuration(awake.allowance_seconds)}`
                  : awakeDuration(row.seconds)}
            </output>
          </div>
        ))}
      </div>
    </section>
  );
}

function AllowanceControl({
  look,
  awake,
  busy,
  setAllowance,
}: {
  look: SlackAwakeLook;
  awake: SlackAwake;
  busy: boolean;
  setAllowance(seconds: number | null): void;
}) {
  const hours = awake.allowance_seconds / HOUR;
  const [draft, setDraft] = useState(String(hours));
  const maxHours = awake.max_seconds / HOUR;
  if (look === "presets") {
    const options = ALLOWANCE_PRESETS.filter((s) => s <= awake.max_seconds).map((s) => ({
      value: String(s),
      label: s === 0 ? "Never" : awakeDuration(s),
    }));
    if (!options.some((o) => o.value === String(awake.allowance_seconds))) {
      options.push({ value: String(awake.allowance_seconds), label: awakeDuration(awake.allowance_seconds) });
    }
    return (
      <Select
        label="Awake time per teammate"
        value={String(awake.allowance_seconds)}
        options={options}
        disabled={busy}
        closeOnPick
        align="end"
        onChange={(value) => setAllowance(Number(value))}
      />
    );
  }
  if (look === "slider") {
    return (
      <label className="slack-awake-slider">
        <input
          type="range"
          min={0}
          max={Math.min(maxHours, 12)}
          step={0.5}
          value={hours}
          disabled={busy}
          aria-label="Awake hours per teammate"
          onChange={(event) => setAllowance(Math.round(Number(event.target.value) * HOUR))}
        />
        <output>{hours === 0 ? "Never" : awakeDuration(awake.allowance_seconds)}</output>
      </label>
    );
  }
  return (
    <form
      className="accounts-buttons"
      onSubmit={(event) => {
        event.preventDefault();
        const next = Number(draft);
        if (Number.isFinite(next) && next >= 0 && next <= maxHours) setAllowance(Math.round(next * HOUR));
      }}
    >
      <Input
        className="field"
        type="number"
        inputMode="decimal"
        min={0}
        max={maxHours}
        step={0.5}
        size="sm"
        aria-label="Awake hours per teammate"
        value={draft}
        disabled={busy}
        onChange={(event) => setDraft(event.target.value)}
      />
      <span className="row-help">h</span>
      <Button className="button" type="submit" disabled={busy || draft === String(hours)}>
        Save
      </Button>
    </form>
  );
}
