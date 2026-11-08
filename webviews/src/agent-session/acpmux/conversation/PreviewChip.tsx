// A dev server's page on the command that started it: the globe and its address (`localhost:5173`)
// at the edge of a background command's row while it runs (CommandRow.tsx), and as a part of the
// running turn's line (WorkingFor.tsx). acpmux says which page a process serves (`preview`, an
// address its own output printed that accepted a loopback connect, hub/processes.rs), so the chip
// shows only once the page answers and leaves when the process ends. A click opens the page beside
// the chat, as Session Info's Servers row does (`pane.action` preview). It sits where the running
// row has no mark, so its arrival moves nothing.
import type { KeyboardEvent, MouseEvent } from "react";
import { useContext } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { PreviewChipsContext, previewAddress } from "./previewChipModel";

const CHIP_ICON = rowIconSize(12);

/// The chip of the command `toolCallId` started, or nothing while it serves no page.
export function PreviewChip({ toolCallId }: { toolCallId: string }) {
  const t = useT();
  const chips = useContext(PreviewChipsContext);
  const preview = chips?.byTool.get(toolCallId);
  if (!chips || !preview) return null;
  const open = (event: MouseEvent | KeyboardEvent) => {
    // The chip sits in the row's toggle: opening the page never opens or closes the row.
    event.preventDefault();
    event.stopPropagation();
    chips.open(preview);
  };
  return (
    <span
      className="cv-preview-chip"
      // An <a> may not sit in the row's <button>; a link role with its own keys does (as
      // BackgroundTaskNote.tsx's owner link).
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="link"
      tabIndex={0}
      aria-label={t("sessionInfo.servers.open", { url: preview.url })}
      data-find-skip
      onClick={open}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") open(event);
      }}
    >
      <Icon name="link.web" size={CHIP_ICON} row fit />
      <span className="cv-preview-chip__address">{previewAddress(preview.url)}</span>
    </span>
  );
}
