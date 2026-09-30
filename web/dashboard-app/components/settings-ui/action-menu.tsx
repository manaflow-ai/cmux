"use client";

import { Menu } from "@base-ui-components/react/menu";
import { MoreIcon } from "./icons";
import { settingsButtonClass } from "./styles";

export type ActionMenuItem = {
  readonly id: string;
  readonly label: string;
  readonly onSelect: () => void;
  readonly disabled?: boolean;
  /**
   * Why the item is disabled. Rendered under the label (not as a hover-only
   * tooltip) so it is readable on touch screens and by screen readers.
   */
  readonly disabledReason?: string;
  readonly danger?: boolean;
};

const itemClass =
  "flex w-full cursor-default select-none flex-col items-start gap-0.5 px-2.5 py-2 text-left text-sm outline-none data-[highlighted]:bg-code-bg data-[disabled]:cursor-not-allowed";

/** Row-level "more actions" menu, the equivalent of Hexclave's ActionCell. */
export function ActionMenu({
  label,
  items,
  disabled = false,
}: {
  /** Accessible name for the trigger, e.g. "Actions for a@b.com". */
  readonly label: string;
  readonly items: readonly ActionMenuItem[];
  readonly disabled?: boolean;
}) {
  if (items.length === 0) return null;
  return (
    <Menu.Root>
      <Menu.Trigger
        aria-label={label}
        disabled={disabled}
        className={settingsButtonClass("ghost", "sm")}
      >
        <MoreIcon />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner side="bottom" align="end" sideOffset={4} className="z-50">
          <Menu.Popup className="w-60 border border-border bg-background p-1 text-foreground shadow-xl shadow-black/10 outline-none">
            {items.map((item) => (
              <Menu.Item
                key={item.id}
                disabled={item.disabled}
                onClick={item.disabled ? undefined : item.onSelect}
                className={itemClass}
              >
                <span
                  className={
                    item.disabled
                      ? "text-muted"
                      : item.danger
                        ? "text-red-600 dark:text-red-400"
                        : ""
                  }
                >
                  {item.label}
                </span>
                {item.disabled && item.disabledReason ? (
                  <span className="text-[11px] text-muted">{item.disabledReason}</span>
                ) : null}
              </Menu.Item>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}
