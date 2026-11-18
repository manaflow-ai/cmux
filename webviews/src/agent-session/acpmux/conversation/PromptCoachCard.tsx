// The prompt coach card (promptCoach.ts; Leo, 2026-11-08: "go think of things/look at things, esp
// valuable things that people would think \"wow this is awesome\""). After a chat in which the person
// corrected the agent three or more times before moving on, one quiet hairline card under the turn the
// rewrite landed in: "Here's how this could have landed in one shot", after how many corrections, and
// the chat's first prompt rewritten with what the person said later, selectable, its line breaks kept,
// in a block that scrolls past eight lines (so the row's height is known before it draws, model.ts).
// Copy puts the rewrite on the clipboard (CopyButton). The × hides it and the chat never draws one
// again on this device (promptCoachDismissed.ts); without `onDismiss` (a replay, a read-only
// transcript) it draws no ×. It appears whole, never as a placeholder: its record carries the text.
import { memo, useState } from "react";
import { useT } from "../i18n";
import { CopyButton } from "./CopyButton";
import { copyTextResult } from "./clipboard";
import { Close } from "./icons";
import type { PromptCoach } from "./promptCoach";
import "./PromptCoachCard.css";

/// How the card is drawn. `card` (shipped): the recap's and memory card's hairline box, its label
/// line over the rewrite in a tinted prompt block; the rewrite is the point, so it shows at once,
/// framed like the other cards a chat adds under a turn, and Copy sits on the label line where the
/// eye starts. `rule`: no box, a rule on the left like a quote; quieter, but it reads as more of the
/// agent's own text. `compact`: one line until opened; the least room, but the rewrite (the "wow")
/// hides behind a click and the row changes height when it opens. The gallery compares them
/// (PromptCoachCard.gallery.tsx).
export type PromptCoachLook = "card" | "rule" | "compact";

export const PromptCoachCard = memo(function PromptCoachCard({
  coach,
  onDismiss,
  look = "card",
  enter = false,
  copy = copyTextResult,
}: {
  coach: PromptCoach;
  /// The ×. Without it (a read-only or replayed transcript) the card draws no ×.
  onDismiss?: () => void;
  look?: PromptCoachLook;
  /// It arrived while the chat was open: it fades in once (PromptCoachCard.css, through the motion
  /// gate). A card drawn from history, or drawn again after scrolling, just appears.
  enter?: boolean;
  /// Puts the rewrite on the clipboard (a test's or the gallery's stand-in).
  copy?: (text: string) => Promise<boolean>;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const shown = look !== "compact" || open;
  return (
    <section className="cv-coach" data-look={look} data-enter={enter || undefined} aria-label={t("promptCoach.label")}>
      <div className="cv-coach__head">
        <p className="cv-coach__title">
          <span className="cv-coach__label">{t("promptCoach.label")}</span>
          {coach.corrections > 0 && (
            <span className="cv-coach__meta">{t("promptCoach.corrections", { n: coach.corrections })}</span>
          )}
        </p>
        {look === "compact" && (
          <button
            type="button"
            className="cv-coach__toggle"
            aria-expanded={open}
            onClick={() => setOpen((value) => !value)}
          >
            {t(open ? "message.less" : "message.more")}
          </button>
        )}
        <CopyButton
          text={coach.rewrite}
          label={t("promptCoach.copy")}
          className="cv-coach__action cv-coach__copy"
          copy={copy}
          size={14}
          copiedWord
        />
        {onDismiss && (
          <button
            type="button"
            className="cv-coach__action cv-coach__close"
            aria-label={t("promptCoach.dismiss")}
            title={t("promptCoach.dismiss")}
            onClick={onDismiss}
          >
            <Close />
          </button>
        )}
      </div>
      {shown && (
        // Its own scroll past eight lines: a stop on the Tab path so the keys can scroll it too.
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- a scrolling region the keyboard must reach.
        <section className="cv-coach__prompt" tabIndex={0} aria-label={t("promptCoach.rewrite")}>
          {coach.rewrite}
        </section>
      )}
    </section>
  );
});
