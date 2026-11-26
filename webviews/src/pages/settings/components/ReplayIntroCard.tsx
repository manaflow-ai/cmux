// Settings > General, right under Text Size: Replay the Intro reopens the Make cmux Yours step (how you work,
// density, background) on the current settings, the palette's home.makeItYours run through cmux.app.action.run.
// The first-run flag is untouched, and the step's Skip puts back what was set when it opened (decision
// d-eedbe6969c; Leo, 2026-11-22: "and i guess they can maybe replay it to return to the walk of the settings").
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { t } from "../strings";

/** The action the card runs: the palette's Make cmux Yours. */
export const REPLAY_INTRO_ACTION = "home.makeItYours";

export function ReplayIntroCard() {
  const store = useStore();
  return (
    <section className="group replay-intro-card" data-card="replayIntro" aria-labelledby="replay-intro-card-title">
      <div className="replay-intro-card__text">
        <h2 className="group-title" id="replay-intro-card-title">
          {t("settingsPage.replayIntro.title")}
        </h2>
        <p className="replay-intro-card__detail">{t("settingsPage.replayIntro.detail")}</p>
      </div>
      <Button
        type="button"
        className="button replay-intro-card__run"
        data-action={REPLAY_INTRO_ACTION}
        onClick={() => store.runSectionAction(REPLAY_INTRO_ACTION)}
      >
        {t("settingsPage.replayIntro.run")}
      </Button>
    </section>
  );
}
