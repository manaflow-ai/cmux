import { memo, useState } from "react";
import { useT } from "../i18n";
import type { PresetApproval, PresetApprovalOutcome } from "./presetApproval";
import "./PresetApprovalCard.css";

/// How the open card is drawn. `card` (shipped): the memory card's hairline box, the question over
/// what it starts and the warning, Not now and Approve at its foot. `inline`: one compact box with
/// the buttons beside the question. `details`: the box with what it starts as a small label and
/// value table. The gallery compares them (PresetApprovalCard.gallery.tsx).
export type PresetApprovalLook = "card" | "inline" | "details";

/// A no-prompt preset's approval card (presetApproval.ts): an agent of this chat tried to start a
/// chat on another machine from a preset whose policy does not ask, and acpmux refused it until the
/// person approves that preset once. Approve and Not now answer through `onAnswer`
/// (`_acpmux/presets`); a refused answer shows acpmux's message and keeps the card open. Closed, the
/// card folds to one muted line. Without `onAnswer` (a replay, a read-only transcript) it draws no
/// buttons. The card never takes focus by itself.
export const PresetApprovalCard = memo(function PresetApprovalCard({
  approval,
  onAnswer,
  look = "card",
}: {
  approval: PresetApproval;
  onAnswer?: (outcome: PresetApprovalOutcome) => void;
  look?: PresetApprovalLook;
}) {
  const t = useT();
  const { ask, outcome, busy, error } = approval;
  const closed = outcome !== undefined;
  // The last error stays in its fold while the fold closes, so the line shrinks instead of blanking.
  const [shownError, setShownError] = useState(error);
  if (error && error !== shownError) setShownError(error);
  // The agent, as acpmux names its harness, then the preset's model and effort, when it sets them.
  const agent = [ask.harness, ask.model, ask.effort].filter(Boolean).join(" · ");
  const starts = ask.host
    ? t("presetApproval.startsOn", { agent, policy: ask.policy, host: ask.host })
    : t("presetApproval.starts", { agent, policy: ask.policy });
  const answer = (pick: PresetApprovalOutcome) => {
    if (!onAnswer || closed || busy) return;
    onAnswer(pick);
  };
  const buttons = onAnswer && (
    <div className="cv-preset-approval__actions">
      <button
        type="button"
        className="cv-preset-approval__button"
        disabled={busy !== undefined}
        aria-busy={busy === "declined" || undefined}
        onClick={() => answer("declined")}
      >
        {t("presetApproval.notNow")}
      </button>
      <button
        type="button"
        className="cv-preset-approval__button is-primary"
        disabled={busy !== undefined}
        aria-busy={busy === "approved" || undefined}
        onClick={() => answer("approved")}
      >
        {t("presetApproval.approve")}
      </button>
    </div>
  );
  const title = <p className="cv-preset-approval__title">{t("presetApproval.title", { preset: ask.preset })}</p>;
  const description = ask.description && <p className="cv-preset-approval__description">{ask.description}</p>;
  const warning = <p className="cv-preset-approval__warning">{t("presetApproval.warning")}</p>;
  const what =
    look === "details" ? (
      <dl className="cv-preset-approval__table">
        <dt>{t("presetApproval.agent")}</dt>
        <dd>{agent}</dd>
        <dt>{t("presetApproval.policy")}</dt>
        <dd>{ask.policy}</dd>
        {ask.host && (
          <>
            <dt>{t("presetApproval.machine")}</dt>
            <dd>{ask.host}</dd>
          </>
        )}
      </dl>
    ) : (
      <p className="cv-preset-approval__starts">{starts}</p>
    );
  const note =
    outcome === "approved"
      ? t("presetApproval.approved", { preset: ask.preset })
      : t("presetApproval.declined", { preset: ask.preset });

  return (
    <section
      className="cv-preset-approval"
      data-look={look}
      data-closed={closed}
      aria-label={t("presetApproval.label", { preset: ask.preset })}
      aria-live="polite"
    >
      <div className="cv-preset-approval__fold cv-preset-approval__body" data-open={!closed} inert={closed}>
        <div className="cv-preset-approval__clip">
          {look === "inline" ? (
            <div className="cv-preset-approval__row">
              <div className="cv-preset-approval__text">
                {title}
                {what}
              </div>
              {buttons}
            </div>
          ) : (
            <>
              {title}
              {description}
              {what}
            </>
          )}
          {warning}
          <div className="cv-preset-approval__fold" data-open={error !== undefined}>
            <div className="cv-preset-approval__clip">
              <output className="cv-preset-approval__error" role="alert">
                {shownError}
              </output>
            </div>
          </div>
          {look !== "inline" && buttons && <div className="cv-preset-approval__foot">{buttons}</div>}
        </div>
      </div>
      <div className="cv-preset-approval__fold" data-open={closed} inert={!closed}>
        <div className="cv-preset-approval__clip">
          <p className="cv-preset-approval__note">{note}</p>
        </div>
      </div>
    </section>
  );
});
