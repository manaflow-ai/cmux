// "⌃B to run in background" at the right of a running turn's live line while a command runs
// (Thinking.tsx, WorkingFor.tsx), never on the command's own transcript row (Leo, 2026-10-22: "it
// should prob go down"). Claude Code says it too; only while Ctrl-B moves something
// (runInBackground.ts), so it never offers what nothing can do. It is a button that does what Ctrl-B
// does: Ctrl-B goes to whichever pane has the keyboard, and the hint shows on hover in a pane that
// may not (Leo, 2026-11-03: "this run in background sometimes i can't actually do anything to put it
// in the background"). It fades in after a moment, so a quick command never shows it. Its room is
// kept while it is offered, so pointing at the line changes its opacity and nothing else: taking
// its room on hover squeezed the line's times and tokens over each other (Leo, 2026-11-06: "this
// flickers"; backgroundHintRoom.experiment.ts). Since that room is kept even before it shows, it is
// a small ⌃B key cap by default, its tooltip saying what it does, and it leaves a tight line first, so
// the command keeps its room (Leo, 2026-11-20: "the ctrl b to run in background is just too much too
// long and to obtrusive at default because it reserves so much shit"; backgroundHintLabel.experiment.ts,
// conversation.css). Find skips it: it is a hint, not output.
import { useContext } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT } from "../i18n";
import { backgroundHintLabel } from "./backgroundHintLabel.experiment";
import { backgroundHintRoom } from "./backgroundHintRoom.experiment";
import { RunInBackgroundContext } from "./runInBackground";

/// The key it names, drawn as a key cap: a key glyph, the same in every language.
const KEY = "⌃B";

export function BackgroundHint() {
  const t = useT();
  const runInBackground = useContext(RunInBackgroundContext);
  if (!runInBackground) return null;
  const label = t("tools.backgroundHintLabel");
  return (
    <button
      type="button"
      className="cv-command__bg"
      data-room={experimentArm(backgroundHintRoom)}
      data-label={experimentArm(backgroundHintLabel)}
      aria-label={label}
      title={label}
      data-find-skip
      onClick={(event) => {
        event.stopPropagation();
        runInBackground();
      }}
    >
      {/* Both looks are drawn; the arm and the line's width pick one (conversation.css). */}
      <kbd className="cv-command__bg-key">{KEY}</kbd>
      <span className="cv-command__bg-words">{t("tools.backgroundHint")}</span>
    </button>
  );
}
