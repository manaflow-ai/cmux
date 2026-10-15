import { Menu, MenuButton, MenuItem, MenuPopup } from "../../ui/Menu";
import { useT } from "./i18n";
import { LockIcon, ChevronIcon } from "./ComposerPickers";

/** The single quiet summary for trust and chat-wide permission grants.
 *
 * Granted state belongs beside the controls that can change it. Keeping it out of the transcript
 * prevents a completed answer from becoming a second, full-width status card.
 */
export function PermissionStatus({
  trusted,
  chatAllowed,
  trustLabel,
  recentTrust = false,
  onUndoTrust,
  onRevoke,
}: {
  trusted: boolean;
  chatAllowed: boolean;
  trustLabel?: string;
  recentTrust?: boolean;
  onUndoTrust?(): void;
  onRevoke?(): void;
}) {
  const t = useT();
  if (!trusted && !chatAllowed) return null;
  const label = trusted && !chatAllowed ? (trustLabel ?? t("trust.trustedPrivate")) : t("permission.allowChat");
  return (
    <span className="acpmux-permission-status">
      <Menu>
        <MenuButton
          className="acpmux-permission-status-trigger"
          label={label}
          title={label}
          aria-haspopup="menu"
          data-menu="permission-status"
        >
          <LockIcon />
          <span className="acpmux-permission-status-label">{label}</span>
          <ChevronIcon />
        </MenuButton>
        <MenuPopup side="top" align="start" className="acpmux-permission-status-menu">
          {onRevoke && chatAllowed && <MenuItem onSelect={onRevoke}>{t("permission.revoke")}</MenuItem>}
          {onUndoTrust && trusted && <MenuItem onSelect={onUndoTrust}>{t("trust.undo")}</MenuItem>}
        </MenuPopup>
      </Menu>
      {recentTrust && trusted && onUndoTrust && (
        <button type="button" className="acpmux-permission-status-undo" onClick={onUndoTrust}>
          {t("trust.undo")}
        </button>
      )}
    </span>
  );
}
