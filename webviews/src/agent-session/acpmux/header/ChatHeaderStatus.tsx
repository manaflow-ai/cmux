import { Icon } from "../icons/Icon";

/** The slot stays in place; the problem label cannot resize it or move the header tools. */
export function ChatHeaderStatus({ status, detail }: { status: string; detail?: string }) {
  return <div className="acpmux-header-status-slot">{status && <StatusLabel status={status} detail={detail} />}</div>;
}

/** The same label at the start of the tools, for a header in the pane's tab row: the slot's part of
 * that row is under the App's tabs, so a disconnected chat would show no warning at all. */
export function ChatHeaderInlineStatus({ status, detail }: { status: string; detail?: string }) {
  return status ? <StatusLabel status={status} detail={detail} inline /> : null;
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
