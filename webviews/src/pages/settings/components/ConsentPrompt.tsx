import { Button } from "../../../ui/Button";
import type { SchemaRow } from "../schema";
import { t, text } from "../strings";

/**
 * Toggles that send something off the person's machines: the page shows the row's `help` (its consent
 * text, from schemas/settings/source) with Turn On and Cancel before it writes `true`. Turning one off
 * never asks. `diagnostics.shareInstallCounts` is the person's install counts choice, which the platform
 * reports to their Cloud machines as `usage_sharing` (cmuxterm-hq plans/cloud/images-per-user.md).
 */
export const CONSENT_ROWS: ReadonlySet<string> = new Set(["diagnostics.shareInstallCounts"]);

export function asksConsent(row: SchemaRow): boolean {
  return row.kind === "toggle" && CONSENT_ROWS.has(row.key) && text(row.help) !== "";
}

/** The consent text under the row, with Turn On (writes true) and Cancel (writes nothing). */
export function ConsentPrompt({
  row,
  labelId,
  onAccept,
  onCancel,
}: {
  row: SchemaRow;
  labelId: string;
  onAccept(): void;
  onCancel(): void;
}) {
  return (
    <div className="accounts-body">
      <div className="accounts-form" role="alertdialog" aria-labelledby={labelId} data-consent-prompt={row.key}>
        <span className="row-help">{text(row.help)}</span>
        <div className="accounts-buttons">
          <Button type="button" className="button" data-consent-action="accept" onClick={onAccept}>
            {t("settingsWindow.cloud.turnOn")}
          </Button>
          <Button type="button" className="button" data-consent-action="cancel" onClick={onCancel}>
            {t("settingsWindow.cancel")}
          </Button>
        </div>
      </div>
    </div>
  );
}
