// The triage strip (wow idea 22): one quiet line on top of the asks stack while this chat's ask
// waits, saying what the triage keys do here before either is pressed: Ctrl-Cmd-Y answers this ask
// (allow once, approve the plan, or the question's first choice, named) and opens the next waiting
// chat, Ctrl-Cmd-; opens the next one without answering. The ask's card under it shows the exact
// command, plan or question being answered. It comes and goes with the ask, in the same stack and
// the same frame, so nothing moves on its own; its counts change in place. With no triage key bound
// it draws nothing. It reads the Needs you list the page already holds: no timer, no request.
import { Keycap } from "../Keycap";
import { useT } from "../i18n";
import { shortAge } from "../sessionList";
import { SHORTCUT_ACTIONS, useShortcut } from "../shortcuts";
import type { TriageMove } from "./triage";

import "./triage.css";

/// How the strip draws: one line with the age, the count and both keys (`strip`, shipped), only
/// the keys (`keys`), or the count and the answer key as one chip (`chip`). The gallery shows all three.
export type TriageStripLook = "strip" | "keys" | "chip";

export function TriageStrip({
  move,
  others,
  at,
  now = Date.now(),
  look = "strip",
}: {
  move: TriageMove;
  /// Other chats waiting on the person.
  others: number;
  /// When this ask was first seen waiting.
  at?: number;
  now?: number;
  look?: TriageStripLook;
}) {
  const t = useT();
  const answerKey = useShortcut(SHORTCUT_ACTIONS.triageAnswer);
  const nextKey = useShortcut(SHORTCUT_ACTIONS.triageNext);
  if (!answerKey) return null;
  const answer =
    move.kind === "allow"
      ? t(move.plan ? "triage.approveNext" : "triage.allowNext")
      : move.kind === "choice"
        ? t("triage.pickNext", { choice: move.answer.label })
        : t("triage.skip");
  const age = at === undefined ? "" : shortAge(at, now, t);
  const facts = [
    look === "strip" && age ? t("triage.waited", { age }) : undefined,
    look !== "keys" && others > 0 ? t("triage.others", { n: others }) : undefined,
  ].filter(Boolean);
  return (
    <div className="acpmux-triage" data-look={look} data-move={move.kind} role="note" aria-label={t("triage.label")}>
      {facts.length > 0 && <span className="acpmux-triage-facts">{facts.join(" · ")}</span>}
      <span className="acpmux-triage-keys">
        <span className="acpmux-triage-key" data-key="answer">
          <Keycap>{answerKey}</Keycap>
          <span className="acpmux-triage-key-label">{answer}</span>
        </span>
        {nextKey && look !== "chip" && others > 0 && (
          <span className="acpmux-triage-key" data-key="next">
            <Keycap>{nextKey}</Keycap>
            <span className="acpmux-triage-key-label">{t("triage.next")}</span>
          </span>
        )}
      </span>
    </div>
  );
}
