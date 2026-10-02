// The changes view's options, behind the toolbar's More button: Refresh, the view toggles as
// sentences (word wrap, split or unified diff, collapse or expand every file), and Copy git
// apply command. A row that cannot run here is shown disabled.
import { More } from "../changeIcons";
import { useMenuButton } from "./useMenuButton";

/// A menu row, or `null` for a separator.
export type OptionsRow = { label: string; disabled?: boolean; run: () => unknown } | null;

export function OptionsMenu({ rows }: { rows: OptionsRow[] }) {
  const { open, button, menu, onKeyDown, run, toggle } = useMenuButton();
  return (
    <span className="acpmux-file-menu">
      <button
        ref={button}
        type="button"
        className="acpmux-diff-tool"
        data-tool="options"
        aria-label="Changes options"
        title="Changes options"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={toggle}
      >
        <More />
      </button>
      {open && (
        <div
          ref={menu}
          role="menu"
          tabIndex={-1}
          className="acpmux-file-menu-list"
          aria-label="Changes options"
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
                disabled={row.disabled}
                onClick={() => run(row.run)}
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
