// The hat over the composer (SubagentTray.tsx), tucked away: its one line folded further, to
// nothing (Leo, 2026-11-04: "what if you wanted to collapse that one line? ... at the top of the
// middle ... some sort of little thing that's like ... a special kind of chevron ... if you hover
// around that range, when it's completely almost like, yeah, hidden, then you can hover around that,
// the top of the composer, and then you can click that to like unleash the hat"). It takes no height
// in the bottom stack: a strip at the top middle of the composer shows an up chevron, a drawer's pull
// tab, on hover or keyboard focus, and a click brings the hat back (`agentPane.display.trayTucked`,
// chatDisplay.ts). The hat's own chevron, the palette, the CLI and MCP tuck it away again.
import React from "react";
import { setTrayTucked } from "../chatDisplay";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";

/// The hat's own chevron (SubagentTray.tsx `onTuck`): one function, so the memoized tray keeps its props.
export const tuckTray = () => setTrayTucked(true);

export function TrayPullTab({ running }: { running: boolean }) {
  const t = useT();
  return (
    <div className="acpmux-tray-pull" data-running={running || undefined}>
      <button
        type="button"
        className="acpmux-tray-pull__tab"
        aria-label={t("tray.untuck")}
        title={t("tray.untuck")}
        onClick={() => setTrayTucked(false)}
      >
        <Icon name="disclosure.expanded" size={12} />
      </button>
    </div>
  );
}
