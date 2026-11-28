// Slack and Chief are invariant product names; all card copy uses the Settings catalog.
import { Button } from "../../../ui/Button";
import { Select } from "../../../ui/Select";
import { t } from "../strings";
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
    label: s === 0 ? t("settingsPage.slack.awake.never") : awakeDuration(s),
  }));
  if (!options.some((o) => o.value === String(awake.allowance_seconds))) {
    options.push({ value: String(awake.allowance_seconds), label: awakeDuration(awake.allowance_seconds) });
    options.sort((a, b) => Number(a.value) - Number(b.value));
  }
  return (
    <section className="group" data-card="slack-awake" aria-busy={busy}>
      <h3 className="group-title">{t("settingsPage.slack.awake.title")}</h3>
      <div className="rows">
        <div className="row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("settingsPage.slack.awake.perTeammate")}</div>
              <div className="row-help">
                {awake.allowance_seconds === 0
                  ? t("settingsPage.slack.awake.ownerOnly")
                  : t("settingsPage.slack.awake.others", awakeDuration(awake.allowance_seconds))}
              </div>
            </div>
            <div className="row-control">
              <Select
                label={t("settingsPage.slack.awake.selectLabel")}
                value={String(awake.allowance_seconds)}
                options={options}
                disabled={busy}
                closeOnPick
                align="end"
                onChange={(value) => setAllowance(Number(value))}
              />
            </div>
          </div>
        </div>
        {!isDefault && (
          <div className="row">
            <div className="row-main">
              <div className="row-label row-help">
                {t("settingsPage.slack.awake.defaultIs", awakeDuration(awake.default_seconds))}
              </div>
              <div className="row-control">
                <Button
                  className="link-button"
                  variant="ghost"
                  size="sm"
                  disabled={busy}
                  onClick={() => setAllowance(null)}
                >
                  {t("settingsPage.slack.awake.useDefault")}
                </Button>
              </div>
            </div>
          </div>
        )}
        <div className="row" data-slack-awake="spent">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("settingsPage.slack.awake.spent")}</div>
              {rows.length === 0 && <div className="row-help">{t("settingsPage.slack.awake.spentNone")}</div>}
            </div>
          </div>
        </div>
        {rows.map((row) => (
          <div className="row" key={row.user} data-slack-awake-sender={row.user}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">{row.owner ? t("settingsPage.slack.awake.you", row.name) : row.name}</div>
                <div className="row-help">
                  {row.turns === 1
                    ? t("settingsPage.slack.awake.oneMessage")
                    : t("settingsPage.slack.awake.messages", row.turns)}
                  {row.used === 1 && !row.owner ? ` · ${t("settingsPage.slack.awake.outToday")}` : ""}
                </div>
              </div>
              <output className="row-control row-value">
                {row.used !== null
                  ? `${awakeDuration(row.seconds)} / ${awakeDuration(awake.allowance_seconds)}`
                  : awakeDuration(row.seconds)}
              </output>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
