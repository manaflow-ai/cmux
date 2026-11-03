// What a background task's end left on the call that started it (direct.ts `attachReaction`; Leo,
// 2026-11-03: "there's like... background tasks worth responding to and not worth responding to").
// A final result the person has not seen is a small accent dot at the row's edge, beside its check,
// until their next prompt (the `background-reaction-look` experiment's "On the call" arm). The
// agent's reply to it, when it wrote one, opens with the call: one muted paragraph under its
// output, which Find reads, so nothing the agent said is out of reach.
import { experimentArm } from "../../../experiments/experiment";
import { useT } from "../i18n";
import { backgroundReactionLook, marksNew, reactsOnCall } from "./backgroundReaction.experiment";
import type { AcpmuxBackgroundReaction } from "../model";

export function ReactionMark({ reaction }: { reaction: AcpmuxBackgroundReaction | undefined }) {
  const t = useT();
  if (!reaction?.fresh || !marksNew(experimentArm(backgroundReactionLook))) return null;
  const label = t("backgroundReaction.new");
  return (
    // tooltip-allow: the dot's only words; its label is for screen readers too
    <span className="cv-reaction-mark" title={label} data-state="new">
      <span className="cv-command__bg-label" data-find-skip>
        {label}
      </span>
    </span>
  );
}

export function ReactionReply({ reaction }: { reaction: AcpmuxBackgroundReaction | undefined }) {
  if (!reaction?.text || !reactsOnCall(experimentArm(backgroundReactionLook))) return null;
  return <p className="cv-reaction-reply">{reaction.text}</p>;
}
