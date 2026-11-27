import React, { useState } from "react";
import { useT } from "../i18n";
import { FisheyeFilters } from "../../../ui/glass/Fisheye";
import { leaveOnScreenRef } from "../../../ui/tabReach";
import { ArrowDown } from "../conversation/icons";
import { Slot } from "../../../slots/Slot";
import { jumpToBottomSlot } from "../../../slots/jumpToBottom";
import { type TranscriptNeedsYou, NeedsYouPill } from "../needsYou/JumpPill";
import { experimentArm } from "../../../experiments/experiment";
import { jumpPairLook, type JumpUpBadge } from "../jumpPair.experiment";
import { JumpDots } from "../conversation/JumpDots";
import { useThinkingLook } from "../conversation/thinkingLook";

/// Jump to latest's diameter, CSS px (conversation.css .acpmux-jump-latest): its fisheye filter is
/// drawn for it (ui/glass/Fisheye.tsx).
const JUMP_LATEST_SIZE = 32;

/// Jump to latest: a glass control centered above the composer, shown while the reader is scrolled up
/// from the latest message (ChatGPT and Codex style). Its look is the `jump-pair-look` experiment
/// (jumpPair.experiment.ts, jumpPair.css): a frosted disc by default (Leo 2026-11-12, of the fisheye
/// disc: "a little bit strange-looking"); the `lens` arm keeps the fisheye that magnifies the
/// transcript under it (Leo 2026-10-21: "I want more fisheye!"). Its mark is the `chat.jumpToBottom` theme slot:
/// the default variant stays a static arrow while the agent works (the shared transcript spinner shows the work),
/// and a theme's variant may move while `working`. It stays mounted while
/// hidden (inert) so it fades out as it fades in (conversation.css).
export function JumpToLatest({
  shown,
  working,
  onJump,
  lift,
  needsYou,
  up,
}: {
  shown: boolean;
  /// Pointing up at the first unseen row (jumpControl.ts): the arrow turns, the label says unread, and
  /// the badge arm (jumpPair.experiment.ts `jumpUpBadge`) may count the turns.
  up?: { badge: JumpUpBadge; turns: number };
  working: boolean;
  /// Open asks (needsYou/JumpPill.ts): the button becomes the Needs your input pill.
  needsYou?: TranscriptNeedsYou;
  /// The bottom stack's height over the transcript's foot: the button sits above it.
  lift: number;
  /// `focused`: the button had keyboard focus, which it loses when it hides at the latest message.
  onJump: (focused: boolean) => void;
}) {
  const t = useT();
  const [look] = useState(() => experimentArm(jumpPairLook));
  // A look's working dots (thinkingLook.ts `jumpButton: "dots"`, off by default): drawn over the arrow's
  // cell while the agent works; the arrow comes back on hover and focus (JumpDots.css).
  const dots = useThinkingLook().jumpButton === "dots" && working;
  if (!up && needsYou && needsYou.count > 0)
    return <NeedsYouPill {...needsYou} shown={shown} lift={lift} onJump={onJump} />;
  const label = up ? t("transcript.jumpUnread") : t(working ? "transcript.jumpLatestWorking" : "transcript.jumpLatest");
  const lens = look === "lens";
  return (
    <>
      {lens && <FisheyeFilters size={JUMP_LATEST_SIZE} />}
      <button
        type="button"
        ref={leaveOnScreenRef}
        className={
          (lens ? "ui-glass ui-glass-fisheye acpmux-jump-latest" : "ui-glass acpmux-jump-latest") +
          (up ? " acpmux-jump-up" : "")
        }
        data-look={look}
        data-jump={up ? "up" : "latest"}
        data-badge={up?.badge}
        data-shown={shown ? "" : undefined}
        data-working-dots={dots ? "" : undefined}
        // Its keyboard focus is its own wash over the glass (conversation.css), not the shared one,
        // whose `box-shadow: none` took the glass's rim and shadow away while it was focused.
        data-focus-ring="none"
        style={lift > 0 ? ({ "--acpmux-dock-space": `${lift}px` } as React.CSSProperties) : undefined}
        aria-label={label}
        // tooltip-allow: the arrow says nothing by itself; working state is carried by the shared spinner in the transcript.
        title={label}
        // Hidden, it is inert: out of the tab order and the accessibility tree while it fades out.
        inert={!shown}
        // A click does not focus a button in WebKit, so focus on it means Return or Space.
        onClick={(event) => onJump(event.currentTarget === document.activeElement)}
      >
        {/* The mark is a theme slot (schemas/theme/slots.json `chat.jumpToBottom`): its default variant
            draws exactly the static arrow this button drew before. */}
        {up ? (
          <span className="acpmux-jump-latest__arrow" aria-hidden="true">
            <ArrowDown size={14} />
          </span>
        ) : (
          <Slot slot={jumpToBottomSlot} props={{ shown, working }} />
        )}
        {dots && !up && <JumpDots />}
        {up?.badge === "count" && up.turns > 0 && (
          <span className="acpmux-jump-latest__count" aria-hidden="true">
            {up.turns > 99 ? "99+" : up.turns}
          </span>
        )}
        {look === "labeled" && (
          <span className="acpmux-jump-latest__label">{t(up ? "transcript.jumpUnread" : "transcript.jumpLatest")}</span>
        )}
      </button>
    </>
  );
}
