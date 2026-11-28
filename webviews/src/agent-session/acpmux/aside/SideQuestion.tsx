import { RevealedMarkdown } from "../conversation/RevealedMarkdown";
import { useT } from "../i18n";

/// A side question (`/btw`, cx-ef2m) while it is asked or answered. acpmux answers it in a
/// throwaway copy of the chat (`_acpmux/ask`), so the chat never holds it.
export type SideQuestionState = { question: string; answer?: string; error?: string };

/// The side question above the composer. Dismiss forgets it; Add to chat sends the question to the
/// chat as a prompt, so the chat answers it as one of its turns.
export function SideQuestion({
  state,
  githubRepository,
  onAdd,
  onDismiss,
}: {
  state: SideQuestionState;
  githubRepository?: string;
  onAdd(): void;
  onDismiss(): void;
}) {
  const t = useT();
  const asking = state.answer === undefined && state.error === undefined;
  return (
    <section className="acpmux-side-question" aria-label={t("sideQuestion.label")} aria-busy={asking}>
      <p className="acpmux-side-question-asked">
        <span className="acpmux-side-question-label">{t("sideQuestion.label")}</span> {state.question}
      </p>
      {asking ? (
        <p className="acpmux-side-question-status">{t("sideQuestion.asking")}</p>
      ) : state.error !== undefined ? (
        <p className="acpmux-side-question-error">{state.error}</p>
      ) : (
        <div className="acpmux-side-question-answer">
          <RevealedMarkdown text={state.answer ?? ""} streaming={false} githubRepository={githubRepository} />
        </div>
      )}
      <div className="acpmux-side-question-actions">
        <button type="button" className="acpmux-side-question-button" onClick={onAdd}>
          {t("sideQuestion.add")}
        </button>
        <button type="button" className="acpmux-side-question-button" onClick={onDismiss}>
          {t("sideQuestion.dismiss")}
        </button>
      </div>
    </section>
  );
}
