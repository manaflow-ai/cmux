// The changes view's options, behind the toolbar's More button: Refresh, the view toggles as
// sentences (word wrap, split or unified diff, collapse or expand every file), and Copy git
// apply command. A row that cannot run here is shown disabled; it stays in the menu for the
// keyboard and a screen reader, and does nothing.
import { useRef } from "react";
import { More } from "../changeIcons";
import { useT } from "../i18n";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../../ui/Menu";

/// A menu row, or `null` for a separator.
export type OptionsRow = { label: string; disabled?: boolean; run: () => unknown } | null;

export function OptionsMenu({ rows }: { rows: OptionsRow[] }) {
  const t = useT();
  const button = useRef<HTMLButtonElement>(null);
  return (
    <span className="acpmux-file-menu">
      <Menu>
        <MenuButton buttonRef={button} className="acpmux-diff-tool" label={t("changes.options")} aria-haspopup="menu">
          <More />
        </MenuButton>
        <MenuPopup className="acpmux-file-menu-list" side="bottom" align="start" finalFocus={button}>
          {rows.map((row, index) =>
            row ? (
              <MenuItem
                key={row.label}
                className="acpmux-file-menu-item"
                disabled={row.disabled}
                onSelect={() => void Promise.resolve(row.run()).finally(() => button.current?.focus())}
              >
                {row.label}
              </MenuItem>
            ) : (
              <MenuSeparator key={`separator-${index}`} />
            ),
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}
