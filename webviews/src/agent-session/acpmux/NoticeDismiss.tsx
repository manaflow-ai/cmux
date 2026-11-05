import { Close } from "./conversation/icons";
import { useT } from "./i18n";

/// The × that closes an error line above the composer or a failed turn's card (cmux#36329): every
/// error the pane draws can be put away, and one that resolves clears on its own. Muted, no surface
/// until hovered, as the dictation notice's ×.
export function NoticeDismiss({ onDismiss, className }: { onDismiss(): void; className?: string }) {
  const t = useT();
  return (
    <button
      type="button"
      className={`acpmux-notice-dismiss${className ? ` ${className}` : ""}`}
      aria-label={t("notice.dismiss")}
      // tooltip-allow: the × has no text; the tooltip names it
      title={t("notice.dismiss")}
      data-notice-action="dismiss"
      onClick={onDismiss}
    >
      <Close size={12} aria-hidden="true" />
    </button>
  );
}
