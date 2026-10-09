import { Tooltip } from "../../../ui/Tooltip";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";

/** The slot stays in place; the problem label cannot resize it or move the header tools. */
export function ChatHeaderStatus({ status, detail }: { status: string; detail?: string }) {
  const t = useT();
  const failed = status === t("header.failed");
  const reconnecting = status === t("header.reconnecting");
  const icon = failed ? "status.error" : reconnecting ? "status.inprogress" : "status.disconnected";
  const tone = failed ? "text-(--agent-danger)" : reconnecting ? "text-(--acpmux-warning)" : "text-muted";
  return (
    <div className="acpmux-header-status-slot relative h-7 min-w-0 flex-[1_1_0]">
      {status && (
        <Tooltip label={detail ?? status} side="bottom">
          <span
            tabIndex={0}
            aria-label={detail && detail !== status ? `${status}: ${detail}` : status}
            className="absolute inset-0 flex min-w-0 items-center rounded-md outline-offset-2 focus-visible:outline focus-visible:outline-fg"
          >
            <output
              className={`acpmux-status flex min-w-0 items-center gap-1.5 text-detail font-medium ${tone}`}
              title={detail}
              aria-label={detail}
            >
              <Icon name={icon} size={14} className="shrink-0" />
              <span className="truncate">{status}</span>
            </output>
          </span>
        </Tooltip>
      )}
    </div>
  );
}
