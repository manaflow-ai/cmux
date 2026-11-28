import { Notice } from "../../../ui/Notice";
import type { AutoSizeWarning } from "./autoSizeWarningModel";

/**
 * How the row draws (RFD 0144 piece 8). `card`: an inline notice card. `line`: one quiet line in
 * the transcript, no card. `dismissible`: the card with an ×. None of them asks anything: Rust has
 * already sized the run VM (or kept the run here) and the row only says what it did (Leo, on the
 * RFD 0133 three-button warning: "we simply ... do it").
 */
export type AutoSizeNoticeLook = "card" | "line" | "dismissible";

export type AutoSizeWarningLabels = {
  title: string;
  dismiss: string;
};

export type AutoSizeWarningProps = {
  warning: AutoSizeWarning;
  labels: AutoSizeWarningLabels;
  look?: AutoSizeNoticeLook;
  onDismiss?(): void;
};

/**
 * The known-heavy precheck's notice row. Rust decides when it exists and writes its whole sentence
 * (`heavy_precheck::notice`); the row has no buttons, because nothing waits on the person.
 */
export function AutoSizeWarning({ warning, labels, look = "card", onDismiss }: AutoSizeWarningProps) {
  return (
    <div
      className="acpmux-autosize-warning"
      data-look={look}
      data-command={warning.command}
      data-project={warning.project}
    >
      {look === "line" ? (
        <p className="acpmux-autosize-line" role="status">
          <span className="acpmux-autosize-line-mark" aria-hidden="true" />
          {warning.text}
        </p>
      ) : (
        <Notice
          id="autosize-notice"
          kind="toast"
          placement="inline"
          title={labels.title}
          message={warning.text}
          {...(look === "dismissible" && onDismiss ? { onDismiss, dismissLabel: labels.dismiss } : {})}
        />
      )}
    </div>
  );
}
