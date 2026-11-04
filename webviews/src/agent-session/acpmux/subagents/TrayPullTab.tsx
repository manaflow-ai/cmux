// The hat over the composer (SubagentTray.tsx), tucked away: its one line folded further, to
// nothing (Leo, 2026-11-04: "what if you wanted to collapse that one line? ... at the top of the
// middle ... some sort of little thing that's like ... a special kind of chevron ... if you hover
// around that range, when it's completely almost like, yeah, hidden, then you can hover around that,
// the top of the composer, and then you can click that to like unleash the hat"). It takes no height
// in the bottom stack: a strip at the top of the composer shows an up chevron, a drawer's pull tab,
// on hover or keyboard focus, and a click brings the hat back (`agentPane.display.trayTucked`,
// chatDisplay.ts). The hat's own chevron, the palette, the CLI and MCP tuck it away again.
// Tucked, the tab says how many things run and draws a dot when one needs the person: tucking hides
// noise, never a question. Where it sits on the edge is trayGrabber.experiment.ts (Leo: "I also
// wonder if we'd want the grabber/dogear/whatever design thing on maybe the left… or the right…").
import React, { useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { setTrayTucked } from "../chatDisplay";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { trayGrabberLook } from "./trayGrabber.experiment";

/// The hat's own chevron (SubagentTray.tsx `onTuck`): one function, so the memoized tray keeps its props.
export const tuckTray = () => setTrayTucked(true);

export function TrayPullTab({
  running,
  count = 0,
  waiting = 0,
}: {
  /// Something runs (a line or the turn's plan): the grabber in the accent.
  running: boolean;
  /// How many lines run (trayAttention.ts runningCount), said beside the grabber.
  count?: number;
  /// How many lines need the person (trayAttention.ts needsPersonCount), a dot beside the grabber.
  waiting?: number;
}) {
  const t = useT();
  const [side] = useState(() => experimentArm(trayGrabberLook));
  const label = [
    t("tray.untuck"),
    count > 0 ? t("tray.grabber.running", { n: count }) : undefined,
    waiting > 0 ? t("tray.grabber.waiting", { n: waiting }) : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <div className="acpmux-tray-pull" data-running={running || undefined} data-side={side}>
      <button
        type="button"
        className="acpmux-tray-pull__tab"
        aria-label={label}
        title={label}
        data-waiting={waiting > 0 || undefined}
        onClick={() => setTrayTucked(false)}
      >
        <Icon name="disclosure.expanded" size={12} />
        {(count > 0 || waiting > 0) && (
          <span className="acpmux-tray-pull__badge" aria-hidden="true">
            {count > 0 && <span className="acpmux-tray-pull__count">{count}</span>}
            {waiting > 0 && <span className="acpmux-tray-pull__dot" />}
          </span>
        )}
      </button>
    </div>
  );
}
