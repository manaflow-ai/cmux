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
  const run = (row: Exclude<OptionsRow, null>) => {
    // Base UI restores focus when the menu closes. Keep the action detached from that focus
    // lifecycle so a slow clipboard or host operation cannot steal focus back later.
    // Fire-and-forget rows use the same ignored-rejection contract as other host actions.
    void Promise.resolve()
      .then(() => row.run())
      .catch(() => undefined);
  };
  return (
    <span className="acpmux-file-menu">
      <Menu>
        <MenuButton
          buttonRef={button}
          className="acpmux-diff-tool"
          data-tool="options"
          label={t("changes.options")}
          aria-haspopup="menu"
        >
          <More />
        </MenuButton>
        <MenuPopup
          className="acpmux-file-menu-list"
          side="bottom"
          align="start"
          finalFocus={button}
          aria-label={t("changes.options")}
        >
          {rows.map((row, index) =>
            row ? (
              <MenuItem
                key={row.label}
                className="acpmux-file-menu-item"
                disabled={row.disabled}
                onSelect={() => run(row)}
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
