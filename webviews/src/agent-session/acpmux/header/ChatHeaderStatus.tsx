import { Icon } from "../icons/Icon";

/** The slot stays in place; the problem label cannot resize it or move the header tools. */
export function ChatHeaderStatus({ status, detail }: { status: string; detail?: string }) {
  return (
    <div className="acpmux-header-status-slot">
      {status && (
        <output className="acpmux-status" title={detail} aria-label={detail}>
          <Icon name="status.warning" size={13} />
          <span>{status}</span>
        </output>
      )}
    </div>
  );
}
