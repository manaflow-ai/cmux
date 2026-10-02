// The approval menu above the composer's permission chip (permissions-menu.png): the
// agent's ACP session modes as described rows, the current one checked. Unrestricted modes
// read in the warning color, as "Full access" does in the reference.
import { Popover } from "../shell/Popover";
import { COMPOSER_ANCHORS } from "../shell/anchors";
import { IconCheck, IconShieldAlert } from "../shell/icons";
import { IconHand, IconTerminalShield } from "../app/menuIcons";
import "../app/menus.css";

export type ModeChoice = { id: string; name: string; description?: string };

/** Modes that lift the sandbox: drawn as a warning. */
export const isUnrestricted = (id: string) => /full|bypass|danger|yolo/i.test(id);

export function PermissionMenu({
  modes,
  current,
  onPick,
  onDismiss,
}: {
  modes: ModeChoice[];
  current?: string;
  onPick: (id: string) => void;
  onDismiss: () => void;
}) {
  return (
    <Popover anchor={COMPOSER_ANCHORS.permission} onDismiss={onDismiss} className="app-perm pt-perm" role="menu">
      <div className="app-perm__header">
        <span>How should agent actions be approved?</span>
      </div>
      {modes.map((mode, index) => {
        const warning = isUnrestricted(mode.id);
        return (
          <button
            type="button"
            key={mode.id}
            className={`app-perm__item${warning ? " is-warning" : ""}`}
            role="menuitemradio"
            aria-checked={mode.id === current}
            onClick={() => onPick(mode.id)}
          >
            <span className="app-perm__icon">
              {warning ? (
                <IconShieldAlert size={16} strokeWidth={1.25} />
              ) : index === 0 ? (
                <IconHand />
              ) : (
                <IconTerminalShield />
              )}
            </span>
            <span className="app-perm__label">{mode.name}</span>
            <span className="app-perm__desc">{mode.description ?? ""}</span>
            {mode.id === current && <IconCheck className="app-perm__check" size={16} strokeWidth={1.4} />}
          </button>
        );
      })}
    </Popover>
  );
}
