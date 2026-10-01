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

/**
 * Where each disabled reason renders: under its item when only that item has
 * it, once at the end of the menu when several items share it (for example
 * "A team needs at least one admin" on both demote and leave).
 */
export function disabledReasonLayout(items: readonly ActionMenuItem[]): {
  readonly inline: Readonly<Record<string, string>>;
  readonly footer: readonly string[];
} {
  const counts = new Map<string, number>();
  for (const item of items) {
    if (item.disabled && item.disabledReason) counts.set(item.disabledReason, (counts.get(item.disabledReason) ?? 0) + 1);
  }
  const inline: Record<string, string> = {};
  for (const item of items) {
    if (item.disabled && item.disabledReason && counts.get(item.disabledReason) === 1) inline[item.id] = item.disabledReason;
  }
  return { inline, footer: [...counts].filter(([, count]) => count > 1).map(([reason]) => reason) };
}

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
  const reasons = disabledReasonLayout(items);
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
                {reasons.inline[item.id] ? (
                  <span className="text-[11px] text-muted">{reasons.inline[item.id]}</span>
                ) : null}
              </Menu.Item>
            ))}
            {reasons.footer.map((reason) => (
              <p key={reason} className="border-t border-border px-2.5 pb-1.5 pt-2 text-[11px] text-muted">
                {reason}
              </p>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}
