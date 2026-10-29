import type { ReactNode } from "react";
import { Icon } from "../icons/Icon";

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
 * problem, Right's `children` (the compact Environment line) leads the tools instead. */
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
      /* tooltip-allow: the warning's detail, shown nowhere else */ title={detail}
      aria-label={detail}
    >
      <Icon name="status.warning" size={13} />
      <span>{status}</span>
    </output>
  );
}
