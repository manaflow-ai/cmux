// l10n-allow-file: gallery fixtures (sample warnings), not shipped UI.
// The header's top-right buttons with a banner and without, in 140, 280 and 480 px panes (Leo, 2026-11-23: "a banner
// at the top of a single ... line that gets cut off and also inadvertently shifts the ... buttons on the top right
// down with it because they got ... glued in to the row. ... the ... buttons on the top right NEED to be done right,
// especially when things are at compressed width panes."). Two banners: the connection warning that leads the tools
// in the pane's tab row (ChatHeaderInlineStatus) and the line under the header (WatchBanner). The warning is a row
// accessory (tabRow.ts): it takes only the room the buttons leave and hides whole, the "..." carrying a dot, when
// there is none; the buttons fold into the "..." by the pane's width alone. Each variant's buttons sit where the plain
// variant's do at its width; test/chat-header-banner-tools-still.test.ts pins it in the real pane.
import { createElement } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ChatMenuItem } from "./chatHeaderToolsModel";
import { ChatHeaderInlineStatus } from "./ChatHeaderStatus";
import { ChatHeaderTools } from "./ChatHeaderTools";
import { PanelToggle } from "./PanelToggle";
import { tabRowStyle, useTabRowTools, type TabRow } from "./tabRow";
import { WatchBanner } from "../WatchBanner";

type Props = { width: number; status?: string; banner?: boolean };

const noop = () => undefined;
const ROW: TabRow = { height: 40, trailingInset: 12 };
const menu = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", onSelect: noop },
  { key: "copy", label: "Copy", icon: "action.copy", onSelect: noop },
];
const summary = createElement(PanelToggle, {
  className: "acpmux-summary-button",
  label: "Session Info",
  shown: false,
  onToggle: noop,
});
const SHORT = "Disconnected";
const LONG =
  "Failed: acpmux on studio-mac stopped answering while the chat was mid-turn, and the reconnect was refused";

function HeaderBannerTools({ width, status = "", banner = false }: Props) {
  const tools = useTabRowTools(ROW, noop);
  return (
    <div className="acpmux-stage" style={{ ...tabRowStyle(ROW), width, position: "relative", minHeight: 200 }}>
      <header className="acpmux-header" data-tab-row="">
        <div className="acpmux-header-status-slot" />
        <div className="acpmux-handoff-header-tools" ref={tools}>
          <ChatHeaderInlineStatus status={status} detail={status} />
          <ChatHeaderTools
            onTerminal={noop}
            onBrowser={noop}
            hasChanges
            onChanges={noop}
            summary={summary}
            menu={menu}
          />
        </div>
      </header>
      {banner && <WatchBanner family="claude" onTakeOver={noop} onContinue={noop} />}
    </div>
  );
}

// The buttons keep one line and end inside the pane, whatever banner shows.
const oneLine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-handoff-header-tools .acpmux-header-more"));
  const buttons = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-handoff-header-tools button")];
  const tops = new Set(buttons.map((button) => Math.round(button.getBoundingClientRect().top)));
  if (tops.size !== 1) throw new Error("the buttons left their line");
  const stage = ctx.document.querySelector<HTMLElement>(".acpmux-stage")!.getBoundingClientRect();
  if (buttons.some((button) => button.getBoundingClientRect().right > stage.right + 0.5))
    throw new Error("a button runs past the pane");
};

const variants: Record<string, { note: string; props: Props; play: Play }> = {};
for (const width of [140, 280, 480]) {
  variants[`${width}-plain`] = { note: `${width} px pane, no banner.`, props: { width }, play: oneLine };
  variants[`${width}-banner`] = {
    note: `${width} px pane: "${SHORT}" leads the buttons where there is room (else a dot on the "..."), the watch line under the header; no button moves.`,
    props: { width, status: SHORT, banner: true },
    play: oneLine,
  };
  variants[`${width}-long-banner`] = {
    note: `${width} px pane, a long failure: cut to the room the buttons leave (its whole text in the tooltip), never folding or moving a button.`,
    props: { width, status: LONG, banner: true },
    play: oneLine,
  };
}

export default componentEntry<Props>({
  id: "agent-pane.header-banner-tools",
  title: "Chat header: top-right buttons with and without a banner (140/280/480 px)",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 500, normal: 500 },
  anchors: [{ selector: ".acpmux-header-more" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderStatus.tsx#ChatHeaderInlineStatus",
    "agent-session/acpmux/header/tabRow.ts#useTabRowTools",
  ],
  load: async () => HeaderBannerTools,
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants,
});
