import type { ReactNode } from "react";
import { Icon } from "../icons/Icon";
import { TAB_ROW_ACCESSORY } from "./tabRow";

/** The slot stays in place; the problem label cannot resize it or move the header tools. Right's
 * Environment line uses this slot; Left uses the dedicated row below tabs. */
export function ChatHeaderStatus({
  status,
  detail,
  children,
}: {
  status: string;
  detail?: string;
  children?: ReactNode;
}) {
  return (
    <div className="acpmux-header-status-slot">
      {status ? <StatusLabel status={status} detail={detail} /> : children}
    </div>
  );
}

/** The same label at the start of the tools, for a header in the pane's tab row: the slot's part of
 * that row is under the App's tabs, so a disconnected chat would show no warning at all. Without a
 * problem, Right's `children` (the compact Environment line) leads the tools instead.
 * It is a row accessory (tabRow.ts TAB_ROW_ACCESSORY): it takes only the room the buttons leave, so it never folds
 * a button into the "..." nor raises the need that has the App drop the tools out of its tab row onto a line of
 * their own (Leo, 2026-11-23: "a banner at the top of a single ... line that gets cut off and also inadvertently
 * shifts the ... buttons on the top right down with it because they got ... glued in to the row"). With no room it
 * hides whole and the "..." carries a warning dot instead (header.css); the detail stays in its tooltip. */
export function ChatHeaderInlineStatus({
  status,
  detail,
  children,
}: {
  status: string;
  detail?: string;
  children?: ReactNode;
}) {
  return status ? <StatusLabel status={status} detail={detail} inline /> : (children ?? null);
}

function StatusLabel({ status, detail, inline }: { status: string; detail?: string; inline?: boolean }) {
  return (
    <output
      className={inline ? "acpmux-status acpmux-status--inline" : "acpmux-status"}
      {...(inline ? { [TAB_ROW_ACCESSORY]: "" } : {})}
      /* tooltip-allow: the warning's detail, shown nowhere else */ title={detail}
      aria-label={detail}
    >
      <Icon name="status.warning" size={14} />
      <span>{status}</span>
    </output>
  );
}
