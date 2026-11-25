import React from "react";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../../ui/Menu";
import { useT, type StringKey } from "../i18n";
import { setRailShow } from "../chatDisplay";
import { isRailShow, RAIL_SHOWS, type RailShow } from "./railShow";

/// The head control's own name for each choice, short enough for the rail's head.
const SHORT_LABEL = {
  prompts: "minimap.short.prompts",
  mine: "minimap.short.mine",
  received: "minimap.short.received",
  replies: "minimap.short.replies",
  everything: "minimap.short.everything",
  errors: "minimap.short.errors",
  edits: "minimap.short.edits",
  tools: "minimap.short.tools",
  subagents: "minimap.short.subagents",
} as const satisfies Record<RailShow, StringKey>;

/// The control at the rail's head (Settings > Agent Chat > Prompt Rail Button, RAIL_CONTROL_KEY): the
/// name of what the rail shows, in the rail's own muted type, drawn while the pointer is on the rail or
/// a choice other than every prompt is on (threadMinimap.css). It opens the right-click menu's choices,
/// so the rail changes where it is looked at (Leo, 2026-11-21: "customize it immediately?").
export function RailShowControl({
  show,
  offered,
  labels,
  onOpen,
}: {
  show: RailShow;
  offered: ReadonlySet<RailShow>;
  labels: Readonly<Record<RailShow, StringKey>>;
  /// Opening the menu closes the tick's preview card, which would otherwise sit over it.
  onOpen: () => void;
}) {
  const t = useT();
  return (
    <Menu onOpenChange={(open) => open && onOpen()}>
      <MenuButton
        className="acpmux-minimap__show"
        label={t("minimap.showLabel", { show: t(SHORT_LABEL[show]) })}
        data-menu="rail-show"
      >
        {t(SHORT_LABEL[show])}
      </MenuButton>
      <MenuPopup label={t("minimap.showMenu")} side="bottom" align="start" escapes={false}>
        <MenuRadioGroup value={show} onValueChange={(next) => isRailShow(next) && setRailShow(next)}>
          {RAIL_SHOWS.map((each, at) => (
            <React.Fragment key={each}>
              {(at === 3 || at === 5) && <MenuSeparator />}
              <MenuRadioItem value={each} disabled={!offered.has(each)} closeOnClick>
                {t(labels[each])}
              </MenuRadioItem>
            </React.Fragment>
          ))}
        </MenuRadioGroup>
      </MenuPopup>
    </Menu>
  );
}
