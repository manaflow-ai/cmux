import { useState, type ReactNode } from "react";
import { experimentArm } from "../../experiments/experiment";
import { cloudStartAskLook } from "./cloudStartAsk.experiment";
import type { CloudStartAsk as Ask } from "./cloudStartProgress";
import { copyText } from "./conversation/clipboard";
import { useT } from "./i18n";

/// A Cloud start's question in its card, under the person's message (cloudStartProgress.ts `ask`;
/// leo-workspace design/cloud-start.md): its first Claude login, the login copy consent, Codex's
/// sign-in consent or its device code. Leo, 2026-11-06: "btw we ought to have a lot of that ui in react
/// and not swift / like me clicking cloud and starting a chat at all". The host words it and decides
/// what an answer does; a click sends the button's id back (`onAnswer`, `cloud.answerStart`), and the
/// buttons wait until the host takes the question away or asks the next. One filled button at most;
/// a page to open (Codex's sign-in) is a link beside the buttons, never a second button. Laid out by
/// the `cloud-start-ask` experiment's arm.
export function CloudStartAsk({
  ask,
  onAnswer,
}: {
  ask: Ask;
  onAnswer?: (id: string, button: string) => Promise<boolean> | void;
}) {
  const t = useT();
  const arm = experimentArm(cloudStartAskLook);
  const [copied, setCopied] = useState(false);
  const [sent, setSent] = useState(false);
  const code = ask.code;
  const actions = (
    <span className="acpmux-cloud-ask__actions">
      {ask.buttons.map((button) => (
        <button
          key={button.id}
          type="button"
          className="acpmux-cloud-ask__button"
          data-role={button.role}
          disabled={!onAnswer || sent}
          onClick={() => {
            setSent(true);
            // A refused answer (no fresh click, the question already gone) lets the buttons take another.
            void onAnswer?.(ask.id, button.id)?.then((taken) => taken || setSent(false));
          }}
        >
          {button.title}
        </button>
      ))}
      {ask.link && (
        <a className="acpmux-cloud-start__link" href={ask.link.url} target="_blank" rel="noreferrer">
          {ask.link.title}
        </a>
      )}
    </span>
  );
  const codeRow: ReactNode = code && (
    <span className="acpmux-cloud-ask__code-row">
      <code className="acpmux-cloud-ask__code selectable">{code}</code>
      <button
        type="button"
        className="acpmux-cloud-ask__button"
        data-role="normal"
        onClick={() =>
          void copyText(code).then(
            () => setCopied(true),
            () => setCopied(false),
          )
        }
      >
        {copied ? t("code.copied") : t("turn.signIn.copyCode")}
      </button>
    </span>
  );
  return (
    <fieldset
      className={arm === "sheet" ? "acpmux-cloud-ask ui-card ui-glass" : "acpmux-cloud-ask"}
      aria-label={ask.title}
      data-look={arm}
      data-kind={ask.kind}
    >
      {arm === "banner" ? (
        <span className="acpmux-cloud-ask__head">
          <span className="acpmux-cloud-ask__title">{ask.title}</span>
          {actions}
        </span>
      ) : (
        <span className="acpmux-cloud-ask__title">{ask.title}</span>
      )}
      {ask.lines.map((text, index) => (
        <span key={index} className="acpmux-cloud-ask__line selectable">
          {text}
        </span>
      ))}
      {codeRow}
      {arm !== "banner" && actions}
    </fieldset>
  );
}
