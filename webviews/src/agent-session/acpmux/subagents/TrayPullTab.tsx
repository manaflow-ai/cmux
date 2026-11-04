// The hat over the composer (SubagentTray.tsx), tucked away: its one line folded further, to
// nothing (Leo, 2026-11-04: "what if you wanted to collapse that one line? ... at the top of the
// middle ... some sort of little thing that's like ... a special kind of chevron ... if you hover
// around that range, when it's completely almost like, yeah, hidden, then you can hover around that,
// the top of the composer, and then you can click that to like unleash the hat"). It takes no height
// in the bottom stack: a strip on the composer's top edge shows an up chevron, a drawer's pull tab, on
// hover or keyboard focus, and a click brings the hat back (`agentPane.display.trayTucked`,
// chatDisplay.ts). The hat's own chevron, the palette, the CLI and MCP tuck it away again.
//
// Tucked, the tab still flags what needs the person, so tucking hides the noise and never a question
// an agent asked: a dot while something waits on them, else a small count of what runs (Leo said "Yes"
// on 2026-11-04 to "the tucked state, the hover tab with its dot or count"). A click brings the hat
// back folded to its one line; Option-click brings it back opened. The handle sits at the left, the
// middle or the right of the composer's top edge (`agentPane.display.trayHandle`; Leo: "I also wonder
// if we'd want the grabber/dogear/whatever design thing on maybe the left… or the right…").
import React from "react";
import { setTrayTucked, type TrayHandleSide } from "../chatDisplay";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { subagentStatus } from "../summary/SubagentStatusList";
import type { TrayItem } from "./runningTray";
import { rememberTrayOpen } from "./trayFoldMemory";

/// The hat's own chevron (SubagentTray.tsx `onTuck`): one function, so the memoized tray keeps its props.
export const tuckTray = () => setTrayTucked(true);

/// What the tucked tab flags: the lines that wait on the person (counted as the hat's header counts
/// them, trayHeadKinds.ts) and the ones that run.
export function pullTabCounts(
  items: readonly TrayItem[],
  waiting: ReadonlySet<string>,
): { waiting: number; running: number } {
  let waits = 0;
  for (const item of items)
    if (
      item.kind === "agent"
        ? subagentStatus(item.agent, waiting) === "waiting"
        : item.kind === "session" && item.session.state === "waiting"
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
  /// Something runs that the tab does not count (the turn's task list): the grabber takes the accent.
  working: boolean;
  side: TrayHandleSide;
}) {
  const t = useT();
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
        <Icon name="disclosure.expanded" size={12} />
        {waiting > 0 ? (
          <span className="acpmux-tray-pull__dot" aria-hidden="true" />
        ) : (
          running > 0 && (
            <span className="acpmux-tray-pull__count" aria-hidden="true">
              {running}
            </span>
          )
        )}
      </button>
    </div>
  );
}
