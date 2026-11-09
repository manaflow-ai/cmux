// "Set Up cmux" on Home (goal next-first-run-setup): what this Mac still lacks for a first run,
// drawn in Home's chat column above Chief's composer, with no window of its own. Three looks the
// gallery compares (`rows` ships): only the progress and the next row's action (`next`), every row
// in one compact card (`rows`), or a checklist over the composer (`checklist`). `window` draws the
// same rows as the first-run window would, for comparison only. Each row's trailing control keeps
// one slot, so a button, the spinner and the done mark swap in place and nothing moves. The model is
// setupModel.ts; the host runs each action.
import { Spinner } from "../../../../agent-session/acpmux/conversation/icons";
import { Button } from "../../../../ui/Button";
import { StatusGlyph } from "../../../../ui/StatusGlyph";
import type { Strings } from "../strings";
import { nextStep, setupProgress, setupSteps, type SetupAction, type SetupState, type SetupStep } from "./setupModel";
import "../cards.css";

export type SetupLook = "next" | "rows" | "checklist" | "window";
export const DEFAULT_SETUP_LOOK: SetupLook = "rows";

export interface SetupCardProps {
  strings: Strings;
  state: SetupState;
  look?: SetupLook;
  onAction(action: SetupAction): void;
  /** Hide: the card leaves for good (the host records it); Settings keeps every row. */
  onHide(): void;
}

export function SetupCard({ strings, state, look = DEFAULT_SETUP_LOOK, onAction, onHide }: SetupCardProps) {
  const { t, format } = strings;
  const steps = setupSteps(state, strings);
  const next = nextStep(steps);
  const { done, total } = setupProgress(steps);
  const progress = format("home.setup.progress", String(done), String(total));
  const head = (
    <div className="hm-setup__head">
      <span className="hm-setup__title">{t("home.setup.title")}</span>
      <span className="hm-setup__progress">
        <Ring done={done} total={total} />
        {progress}
      </span>
      {look !== "window" && (
        <button type="button" className="hm-setup__hide" onClick={onHide}>
          {t("home.setup.hide")}
        </button>
      )}
    </div>
  );
  const note = <p className="hm-setup__note">{t("home.setup.network")}</p>;
  if (look === "next") {
    return (
      <section className="hm-setup" data-look={look} aria-label={t("home.setup.title")}>
        {head}
        {next ? (
          <div className="hm-setup__next">
            <span className="hm-setup__next-text">
              <span className="hm-setup__row-title">{next.title}</span>
              <span className="hm-setup__row-detail">{next.detail}</span>
            </span>
            <Trailing step={next} onAction={onAction} wide />
          </div>
        ) : (
          <p className="hm-setup__all-done">{t("home.setup.allDone")}</p>
        )}
        {note}
      </section>
    );
  }
  return (
    <section className="hm-setup" data-look={look} aria-label={t("home.setup.title")}>
      {head}
      <ul className="hm-setup__rows">
        {steps.map((step) => (
          <li key={step.id} className="hm-setup__row" data-step={step.id} data-done={step.done ? "" : undefined}>
            {look === "checklist" && (
              <span className="hm-setup__check">
                <StatusGlyph name={step.done ? "done" : "idle"} size={12} />
              </span>
            )}
            <span className="hm-setup__row-text">
              <span className="hm-setup__row-title">{step.title}</span>
              <span className="hm-setup__row-detail">{step.detail}</span>
            </span>
            <Trailing step={step} onAction={onAction} marksDone={look !== "checklist"} />
          </li>
        ))}
      </ul>
      {note}
      {look === "window" && (
        <footer className="hm-setup__footer">
          <Button variant="subtle" size="md" onClick={onHide}>
            {t("home.setup.skip")}
          </Button>
          <Button variant="solid" size="md" onClick={onHide}>
            {t("home.setup.continue")}
          </Button>
        </footer>
      )}
    </section>
  );
}

/** The row's one slot: its buttons, the spinner while it runs, or the done mark (`marksDone`: the
 * checklist marks it at the row's start instead). */
function Trailing({
  step,
  onAction,
  wide,
  marksDone = true,
}: {
  step: SetupStep;
  onAction(action: SetupAction): void;
  wide?: boolean;
  marksDone?: boolean;
}) {
  const { action, secondary } = step;
  return (
    <span className="hm-setup__slot">
      {step.done ? (
        marksDone && <StatusGlyph name="done" size={12} />
      ) : (
        <>
          {secondary && (
            <Button variant="ghost" size="sm" onClick={() => onAction(secondary.run)}>
              {secondary.label}
            </Button>
          )}
          {step.busy ? (
            <Spinner size={16} loading />
          ) : (
            action && (
              <Button variant={wide ? "solid" : "subtle"} size="sm" onClick={() => onAction(action.run)}>
                {action.label}
              </Button>
            )
          )}
        </>
      )}
    </span>
  );
}

/** Progress as a small ring: done of total, drawn in the text color. */
function Ring({ done, total }: { done: number; total: number }) {
  const r = 5;
  const length = 2 * Math.PI * r;
  const filled = total === 0 ? 0 : (done / total) * length;
  return (
    <svg className="hm-setup__ring" width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <circle cx="7" cy="7" r={r} fill="none" strokeWidth="2" className="hm-setup__ring-track" />
      <circle
        cx="7"
        cy="7"
        r={r}
        fill="none"
        strokeWidth="2"
        className="hm-setup__ring-fill"
        strokeDasharray={`${filled} ${length}`}
        transform="rotate(-90 7 7)"
      />
    </svg>
  );
}
