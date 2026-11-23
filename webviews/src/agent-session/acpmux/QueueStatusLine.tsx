// The chat's one status line after a failed turn (queueStatus.ts): the queue's head row while
// prompts wait (ComposerQueue.tsx), the composer notice slot's line while none do (AutoResumeNotice.tsx).
// Plain words first, the retry's countdown and try count after them in the muted ink, the raw error
// behind Details as selectable text, and the queue's Resume where the queue waits for it.
import { useId, useState, type ReactNode } from "react";
import { experimentArm } from "../../experiments/experiment";
import { usePageNow } from "../../ui/pageClock";
import type { Translate } from "./i18n";
import { Icon } from "./icons/Icon";
import { ChevronDown } from "./conversation/icons";
import { countdownText, type QueueStatus } from "./queueStatus";
import { queueStatusLook } from "./queueStatus.experiment";
import "./QueueStatusLine.css";

/// The retry's countdown as its own leaf: the second changes one text node, never the row.
function RetryIn({ t, nextAt }: { t: Translate; nextAt: number }): ReactNode {
  const now = usePageNow(true);
  const left = nextAt - now;
  return left > 0 ? t("queueStatus.retryIn", { time: countdownText(left) }) : t("queueStatus.retryNow");
}

export function QueueStatusLine({
  t,
  status,
  as: Tag = "div",
  className,
  onResume,
  open: openProp,
  onOpenChange,
  autoResume = false,
}: {
  t: Translate;
  status: QueueStatus;
  /// The queue draws it as its list's first item.
  as?: "div" | "li" | "output";
  className?: string;
  /// The queue's Resume (`queue_edit` resume); absent where nothing waits for it.
  onResume?(): void;
  /// Details open, when the host keeps it (the queue sizes its list to it).
  open?: boolean;
  onOpenChange?(open: boolean): void;
  /// The notice slot's retry line (AutoResumeNotice.tsx), marked as the page's tests and its link-down
  /// grace find it.
  autoResume?: boolean;
}) {
  const [look] = useState(() => experimentArm(queueStatusLook));
  const [openOwn, setOpenOwn] = useState(false);
  const open = openProp ?? openOwn;
  const setOpen = (next: boolean) => (onOpenChange ? onOpenChange(next) : setOpenOwn(next));
  const detailsId = useId();
  const retry = status.retry;
  const meta = retry && (
    <span className="acpmux-queue-status-meta">
      {retry.nextAt !== undefined ? <RetryIn t={t} nextAt={retry.nextAt} /> : t("queueStatus.retryNow")}
      <span className="acpmux-queue-status-sep" aria-hidden="true">
        {" · "}
      </span>
      {t("queueStatus.attempt", { attempt: retry.attempt, of: retry.of })}
    </span>
  );
  return (
    <Tag
      className={["acpmux-queue-status", className].filter(Boolean).join(" ")}
      data-look={look}
      data-state={retry ? "retrying" : "paused"}
      data-open={open || undefined}
      data-auto-resume={autoResume ? "waiting" : undefined}
    >
      <span className="acpmux-queue-status-line">
        <span className="acpmux-queue-status-mark" aria-hidden="true">
          {look === "dot" ? (
            <span className="acpmux-queue-status-dot" />
          ) : (
            <Icon name={retry ? "action.retry" : "agent.paused"} size={14} />
          )}
        </span>
        <span className="acpmux-queue-status-copy">
          <span className="acpmux-queue-status-title">{status.title}</span>
          {meta}
        </span>
        {status.error && (
          <button
            type="button"
            className="acpmux-queue-status-button acpmux-queue-status-toggle"
            aria-expanded={open}
            aria-controls={open ? detailsId : undefined}
            onClick={() => setOpen(!open)}
          >
            {t("queueStatus.details")}
            <ChevronDown size={12} className="acpmux-queue-status-chevron" aria-hidden="true" />
          </button>
        )}
        {onResume && (
          <button type="button" className="acpmux-queue-status-button acpmux-queue-resume" onClick={onResume}>
            {t("composer.queueResume")}
          </button>
        )}
      </span>
      {open && status.error && (
        <span id={detailsId} className="acpmux-queue-status-error">
          {status.error}
        </span>
      )}
    </Tag>
  );
}
