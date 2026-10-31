// The changes view's options, behind the toolbar's More button: Refresh, the view toggles as
// sentences (word wrap, split or unified diff, collapse or expand every file), and Copy git
// apply command. A row that cannot run here is shown disabled; it stays in the menu for the
// keyboard and a screen reader, and does nothing.
import { More } from "../changeIcons";
import { useMenuButton } from "./useMenuButton";
import { useT } from "../i18n";
import { useCallback, useState } from "react";
import { UI_ANCHOR_GAP, useUiAnchor } from "../../../ui/anchor";
import { useEscapingPopup } from "../../../ui/popupHost";
import { usePopupHost } from "../../../ui/UiProvider";

/// A menu row, or `null` for a separator.
export type OptionsRow = { label: string; disabled?: boolean; run: () => unknown } | null;

export function OptionsMenu({ rows }: { rows: OptionsRow[] }) {
  const t = useT();
  const { open, button, menu, onKeyDown, run, toggle } = useMenuButton();
  const menuStyle = useUiAnchor(button, menu, open, { side: "below", align: "start" });
  // No room above or below its button in the pane: past the window's edge (popupHost.ts).
  const host = usePopupHost();
  const [shown, setShown] = useState<HTMLDivElement | null>(null);
  const attach = useCallback(
    (node: HTMLDivElement | null) => {
      menu.current = node;
      if (host) setShown(node);
    },
    [host, menu],
  );
  useEscapingPopup(host, shown, () => button.current, {
    side: "bottom",
    align: "start",
    gap: UI_ANCHOR_GAP,
    shell: "self",
  });
  return (
    <span className="acpmux-file-menu">
      <button
        ref={button}
        type="button"
        className="acpmux-diff-tool"
        data-tool="options"
        aria-label={t("changes.options")}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={toggle}
      >
        <More />
      </button>
      {open && (
        <div
          ref={attach}
          style={menuStyle}
          role="menu"
          tabIndex={-1}
          className="ui-popup ui-glass acpmux-file-menu-list"
          aria-label={t("changes.options")}
          onKeyDown={onKeyDown}
        >
          {rows.map((row, index) =>
            row ? (
              <button
                key={row.label}
                type="button"
                role="menuitem"
                tabIndex={-1}
                className="acpmux-file-menu-item"
                aria-disabled={row.disabled || undefined}
                onClick={() => {
                  if (!row.disabled) run(row.run);
                }}
              >
                {row.label}
              </button>
            ) : (
              <hr key={`separator-${index}`} className="acpmux-scope-separator" />
            ),
          )}
        </div>
      )}
    </span>
  );
}
