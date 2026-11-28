import type { ComposerCopyStatus } from "./composerCopy";
import { UploadProgress } from "./attachmentIntake";
import { useT } from "../i18n";
import "./composerCopyStatus.css";

/// A large copy's progress or actionable failure, using the composer's quiet status treatment.
export function ComposerCopyStatusLine({ status }: { status: ComposerCopyStatus }) {
  const t = useT();
  if (!status) return null;
  const fraction =
    status.phase === "copying" ? Math.min(1, Math.max(0, status.written / Math.max(1, status.total))) : 0;
  const label =
    status.phase === "copying"
      ? t("composer.copying", { percent: Math.floor(fraction * 100) })
      : t(status.partial ? "composer.copyIncomplete" : "composer.copyFailed");
  return (
    <div className="acpmux-composer-copy-status">
      {status.phase === "copying" && <UploadProgress value={fraction} name={label} />}
      <output aria-live="polite">{label}</output>
      <button type="button" onClick={status.phase === "copying" ? status.cancel : status.retry}>
        {t(status.phase === "copying" ? "edited.cancel" : "composer.retryAttachment")}
      </button>
    </div>
  );
}
