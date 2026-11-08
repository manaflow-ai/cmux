// The join consent's one-time ask (design/server-cards.md "Join Consent"): who asked for what, the
// question, the note, why an Allow did not take, then Deny and Allow. Allow takes only a click: it
// has no key, and the host takes it only from the person's own click on the card
// (WebCardPanel.isPersonClick), landed on Allow itself: it sends its own rect. Both buttons are off while a write is in flight.
import { DialogButton } from "../../../ui/DialogButton";
import { cx } from "../../../ui/cx";
import type { Strings } from "../../shared/i18n";
import { targetOf, type CardTarget } from "../host";
import { viewOf } from "./model";
import type { JoinConsentStatus } from "./types";

/** How the ask lays out its words (design/server-cards.md, Join Consent variants). */
export type JoinConsentLayout = "stacked" | "compact" | "banner";

export interface JoinConsentCardProps {
  status: JoinConsentStatus | undefined;
  strings: Strings;
  layout?: JoinConsentLayout;
  /** `target`: the pressed button's rect, which the host checks the person's click landed in. */
  onAnswer(allow: boolean, target: CardTarget): void;
}

export function JoinConsentCard({ status, strings, layout = "stacked", onAnswer }: JoinConsentCardProps) {
  const view = viewOf(status, strings);
  if (!view) return null;
  const { t } = strings;
  return (
    <section
      className={cx("server-card join-consent", `join-consent--${layout}`)}
      data-card="join-consent"
      aria-label={view.title}
    >
      {layout === "banner" && <span className="join-consent-mark" aria-hidden="true" />}
      <div className="join-consent-words">
        <h1 className="server-card-title">{view.title}</h1>
        {layout === "compact" ? (
          <p className="server-card-text is-primary">
            {view.question} <span className="join-consent-note">{view.note}</span>
          </p>
        ) : (
          <>
            <p className="server-card-text is-primary">{view.question}</p>
            <p className="server-card-caption">{view.note}</p>
          </>
        )}
        {view.error && (
          <p className="server-card-text is-danger" role="alert">
            {view.error}
          </p>
        )}
      </div>
      <footer className="server-card-footer">
        {!view.enabled && <span className="server-card-spinner" aria-hidden="true" />}
        <span className="server-card-footer-gap" />
        <DialogButton
          dialogKey={null}
          className="server-card-button"
          data-action="deny"
          disabled={!view.enabled}
          onClick={(event) => onAnswer(false, targetOf(event.currentTarget))}
        >
          {t("devices.join.ask.deny")}
        </DialogButton>
        <DialogButton
          dialogKey={null}
          className="server-card-button is-default"
          data-action="allow"
          disabled={!view.enabled}
          onClick={(event) => onAnswer(true, targetOf(event.currentTarget))}
        >
          {t("devices.join.ask.allow")}
        </DialogButton>
      </footer>
    </section>
  );
}
