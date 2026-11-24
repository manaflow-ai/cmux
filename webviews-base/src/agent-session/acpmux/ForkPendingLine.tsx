import { DialogButton } from "../../ui/DialogButton";
import { Spinner } from "./conversation/icons";
import { waitedText } from "./hostErrorModel";
import { useT } from "./i18n";
import { useNow } from "./subagents/subagentGroupModel";

/// How long a fork runs before the line counts its time: a fork that answers sooner shows the
/// line only, no number that changes once and is gone.
export const FORK_COUNT_AFTER_MS = 2000;

/// A Fork Conversation acpmux has not answered yet, in the stack above the composer as the host's
/// waiting line is (bottomStack.css): a spinner, "Forking…", how long after a moment, and Cancel,
/// which takes the fork back whole (direct.ts `cancelFork`). Never a row of the transcript: the
/// chat's own rows stay as they were (Leo, 2026-11-06: "forking text is weird"). `now`: a fixed
/// clock for the gallery; the pane passes none and the line counts each second.
export function ForkPendingLine({ since, onCancel, now: fixedNow }: { since: number; onCancel(): void; now?: number }) {
  const t = useT();
  const ticking = useNow(fixedNow === undefined);
  const waited = (fixedNow ?? ticking) - since;
  return (
    <output className="acpmux-host-line acpmux-fork-pending" aria-live="polite" data-fork-pending>
      <Spinner size={12} loading />
      <span className="acpmux-host-line-message">
        {t("notice.forking")}
        {waited >= FORK_COUNT_AFTER_MS && <span className="acpmux-fork-pending-time">{waitedText(waited)}</span>}
      </span>
      <DialogButton dialogKey={null} onClick={onCancel}>
        {t("fork.cancel")}
      </DialogButton>
    </output>
  );
}
