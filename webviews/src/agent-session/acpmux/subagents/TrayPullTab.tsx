// The hat over the composer (SubagentTray.tsx), tucked away: its one line folded further, to
// nothing (Leo, 2026-11-04: "what if you wanted to collapse that one line? ... at the top of the
// middle ... some sort of little thing that's like ... a special kind of chevron ... if you hover
// around that range, when it's completely almost like, yeah, hidden, then you can hover around that,
// the top of the composer, and then you can click that to like unleash the hat"). It takes no height
// in the bottom stack: a strip on the composer's top edge shows a faint up chevron, a drawer's pull
// tab, that brightens on hover or keyboard focus, and a click brings the hat back (`agentPane.display.trayTucked`,
// chatDisplay.ts). The hat's own chevron, the palette, the CLI and MCP tuck it away again.
//
// Tucked, the tab still flags what needs the person, so tucking hides the noise and never a question
// an agent asked: a dot while something waits on them, else a small count of what runs (Leo said "Yes"
// on 2026-11-04 to "the tucked state, the hover tab with its dot or count"). A click brings the hat
// back folded to its one line; Option-click brings it back opened. The handle sits at the left, the
// middle or the right of the composer's top edge (`agentPane.display.trayHandle`; Leo: "I also wonder
// if we'd want the grabber/dogear/whatever design thing on maybe the left… or the right…").
//
// While nothing runs the hat is just the chevron, centred on the composer; when something runs it
// grows into chevron and count about that centre, and shrinks back when the count clears (Leo,
// 2026-11-07: "if there's no running work, it should just be centered, right? But when there is a
// number, it can, like, you know, grow into that."). One state transition (design/motion.md): the
// count's slot is in the pill from the first frame, and its width and opacity, on one clock, move the
// pill's width, the chevron's place and the count together. Leaving, the slot keeps the last mark
// until its own transition ends, then it goes, so idle keeps no count and no room for one. The motion
// gate (`data-cmux-motion`, WebTheme) ends the transitions at once, and then the mark goes in the
// same frame. Arms in composerHat.experiment.ts.
import React, { useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { setTrayTucked, type TrayHandleSide } from "../chatDisplay";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { subagentStatus } from "../summary/subagentStatusListModel";
import type { TrayItem } from "./runningTray";
import { composerHatLook } from "./composerHat.experiment";
import { asksPerson } from "./trayAttention";
import { rememberTrayOpen } from "./trayFoldMemory";

/// The hat's own chevron (SubagentTray.tsx `onTuck`): one function, so the memoized tray keeps its props.
export const tuckTray = () => setTrayTucked(true);

/// The tab's count as it reads: its control is sized for two digits, so a hundred or more reads "99+".
export const pullTabCountText = (running: number): string => (running > 99 ? "99+" : String(running));

/// What the hat shows past its chevron: the needs-you dot or the running count.
type PullMark = { kind: "dot" } | { kind: "count"; text: string };

const sameMark = (a: PullMark | undefined, b: PullMark | undefined) =>
  a?.kind === b?.kind && (a?.kind !== "count" || a.text === (b as { text: string }).text);

/// The slot's width past the chevron: the dot's size, or one tabular digit (`ch` in the count's own
/// font, subagents.css) per character, so a tick from 3 to 4 keeps the width and 9 to 10 eases it.
const markWidth = (mark: PullMark | undefined): string | undefined =>
  mark === undefined ? undefined : mark.kind === "dot" ? "var(--acpmux-tray-pull-dot)" : `${mark.text.length}ch`;

/// What the tucked tab flags: the lines that wait on the person (counted as the hat's header counts
/// them, trayHeadKinds.ts) and the ones that run. A chat queued for a run slot waits on cmux, not on
/// the person: it counts with what runs, never as a dot (trayAttention.ts asksPerson).
export function pullTabCounts(
  items: readonly TrayItem[],
  waiting: ReadonlySet<string>,
): { waiting: number; running: number } {
  let waits = 0;
  for (const item of items)
    if (
      item.kind === "agent"
        ? subagentStatus(item.agent, waiting) === "waiting"
        : item.kind === "session" && asksPerson(item.session)
    )
      waits += 1;
  return { waiting: waits, running: items.length - waits };
}

export function TrayPullTab({
  chat,
  waiting,
  running,
  working,
  side,
}: {
  /// The chat whose hat comes back: the click sets how it opens (trayFoldMemory.ts).
  chat: string | undefined;
  /// Lines that wait on the person: the tab shows a dot.
  waiting: number;
  /// Lines that run: with none waiting, the tab shows their count.
  running: number;
  /// Something runs that the tab does not count (the turn's task list): the chevron takes the accent.
  working: boolean;
  side: TrayHandleSide;
}) {
  const t = useT();
  const [look] = useState(() => experimentArm(composerHatLook));
  const target: PullMark | undefined =
    waiting > 0 ? { kind: "dot" } : running > 0 ? { kind: "count", text: pullTabCountText(running) } : undefined;
  // The mark drawn: the target, or while leaving the last one, kept until the slot's transition ends.
  const [kept, setKept] = useState(target);
  if (target !== undefined && !sameMark(kept, target)) setKept(target);
  const mark = target ?? kept;
  const leaving = target === undefined && kept !== undefined;
  const slot = useRef<HTMLSpanElement>(null);
  // Nothing to wait for (motion off, a hidden page, no change drawn yet): the mark goes this frame.
  // Reading the slot's animations flushes its style, so a transition that starts is seen here.
  useLayoutEffect(() => {
    if (leaving && !slot.current?.getAnimations().some((animation) => animation.playState === "running"))
      setKept(undefined);
  }, [leaving]);
  const settle = (event: React.TransitionEvent<HTMLSpanElement>) => {
    if (leaving && event.target === event.currentTarget) setKept(undefined);
  };
  const label = [
    t("tray.untuck"),
    waiting > 0 && t("summary.subagents.waiting", { n: waiting }),
    running > 0 && t("summary.subagents.running", { n: running }),
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <div
      className="acpmux-tray-pull"
      data-side={side}
      data-hat={look}
      data-running={running > 0 || working || undefined}
      data-waiting={waiting > 0 || undefined}
    >
      <button
        type="button"
        className="acpmux-tray-pull__tab"
        aria-label={label}
        title={label}
        onClick={(event) => {
          // Back folded to its one line; Option-click opens it at once.
          rememberTrayOpen(chat, event.altKey);
          setTrayTucked(false);
        }}
      >
        <span className="acpmux-tray-pull__hat" data-shown={target !== undefined || undefined}>
          <Icon name="disclosure.expanded" size={12} />
          <span
            ref={slot}
            className="acpmux-tray-pull__slot"
            aria-hidden="true"
            data-shown={target !== undefined || undefined}
            style={{ "--acpmux-tray-pull-mark": markWidth(mark) } as React.CSSProperties}
            onTransitionEnd={settle}
            onTransitionCancel={settle}
          >
            {mark?.kind === "dot" ? (
              <span className="acpmux-tray-pull__dot" />
            ) : (
              mark?.kind === "count" && <span className="acpmux-tray-pull__count">{mark.text}</span>
            )}
          </span>
        </span>
      </button>
    </div>
  );
}
