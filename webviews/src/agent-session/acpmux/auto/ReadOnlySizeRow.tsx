// RFD 0144 piece 9: the Size row with no size control. It says what the computer is now ("now 2 vCPU
// · 4 GB, grows as it works") and offers one request, More room, which names no size. Every value
// comes from the Rust core's `SizeRowView`; this only draws it. The button is a callback: nothing
// here asks the server for a bigger computer.
import "./computerAuto.css";
import { Button } from "../../../ui/Button";
import { Tooltip } from "../../../ui/Tooltip";
import { useT } from "../i18n";
import type { SizeRowView } from "./sizeRowView";

/// The gallery's three looks: the note with the button beside it, the button on its own line under
/// the note, or the button as a small pill after the note.
export type SizeRowLook = "inline" | "stacked" | "pill";

export type ReadOnlySizeRowProps = {
  view: SizeRowView;
  look?: SizeRowLook;
  onMoreRoom(): void;
};

export function ReadOnlySizeRow({ view, look = "inline", onMoreRoom }: ReadOnlySizeRowProps) {
  const t = useT();
  const note = view.pinned
    ? t("computer.size.pinned", { vcpu: view.pinned.vcpu, memory: view.pinned.memory_gib })
    : view.now
      ? t("computer.size.now", { vcpu: view.now.vcpu, memory: view.now.memory_gib })
      : undefined;
  return (
    <div className="acpmux-computer-row acpmux-size-readonly" data-look={look} data-testid="size-row-readonly">
      <span className="acpmux-computer-row-label">{t("computer.row.size")}</span>
      <span className="acpmux-size-body">
        {note ? <span className="acpmux-size-note">{note}</span> : null}
        {view.more_room === "offered" ? (
          <Tooltip label={t("computer.size.moreRoomHelp")}>
            <Button
              size="sm"
              variant={look === "stacked" ? "ghost" : "subtle"}
              className="acpmux-size-more-room"
              onClick={onMoreRoom}
            >
              {t("computer.size.moreRoom")}
            </Button>
          </Tooltip>
        ) : null}
        {view.more_room === "on" ? (
          <span className="acpmux-size-more-room-on">{t("computer.size.moreRoomOn")}</span>
        ) : null}
      </span>
    </div>
  );
}
