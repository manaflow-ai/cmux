// The join consent's one-time ask (design/server-cards.md "Join Consent"): who asked for what, the
// question, the note, why an Allow did not take, then Deny. Allow is the app panel's native
// click-only button under the page (WebCardPanel's PersonControl), never the page's; the gallery
// draws a stand-in in its place. Deny is off while a write is in flight.
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { DialogButton } from "../../../ui/DialogButton";
import { cx } from "../../../ui/cx";
import type { Strings } from "../../shared/i18n";
import { viewOf } from "./model";
import type { JoinConsentStatus } from "./types";

/** How the ask lays out its words (design/server-cards.md, Join Consent variants). */
export type JoinConsentLayout = "stacked" | "compact" | "banner";

export interface JoinConsentCardProps {
  status: JoinConsentStatus | undefined;
  strings: Strings;
  layout?: JoinConsentLayout;
  onDeny(): void;
  /** Draws Allow in the card's footer (the gallery); in the app the panel's native footer does. */
  controlStandIn?: boolean;
}

export function JoinConsentCard({
  status,
  strings,
  layout = "stacked",
  onDeny,
  controlStandIn = false,
}: JoinConsentCardProps) {
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
        {!view.enabled && <Spinner size={12} loading className="server-card-spinner" />}
        <span className="server-card-footer-gap" />
        <DialogButton
          dialogKey={null}
          className="server-card-button"
          data-action="deny"
          disabled={!view.enabled}
          onClick={onDeny}
        >
          {t("devices.join.ask.deny")}
        </DialogButton>
        {controlStandIn && (
          <DialogButton
            dialogKey={null}
            className="server-card-button is-default"
            data-action="allow"
            disabled={!view.enabled}
          >
            {t("devices.join.ask.allow")}
          </DialogButton>
        )}
      </footer>
    </section>
  );
}
