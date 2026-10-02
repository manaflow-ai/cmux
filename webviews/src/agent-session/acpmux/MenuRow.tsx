import { CheckIcon, ChevronRightIcon } from "./ComposerPickers";
import type { MenuNode } from "./useMenuTree";

/// One row of the model picker. A press (not the click after it) picks, so focus stays
/// on the chip and the menu's keys keep working; entering the row hands it to hover intent.
export function MenuRow({
  node,
  id,
  active,
  open,
  onHover,
  onPick,
}: {
  node: MenuNode;
  id: string;
  active: boolean;
  open?: boolean;
  onHover(): void;
  onPick(): void;
}) {
  const submenu = Boolean(node.children?.length || node.panel);
  return (
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions
    <div
      id={id}
      data-key={node.key}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role={node.checked === undefined ? "menuitem" : "menuitemradio"}
      tabIndex={-1}
      aria-checked={node.checked}
      aria-haspopup={node.children?.length ? "menu" : undefined}
      aria-expanded={submenu ? Boolean(open) : undefined}
      className={`acpmux-menu-item acpmux-mp-row${active ? " acpmux-menu-active" : ""}${open ? " acpmux-mp-open" : ""}${node.more ? " acpmux-mp-more" : ""}`}
      onPointerEnter={onHover}
      onMouseDown={(event) => {
        event.preventDefault();
        onPick();
      }}
    >
      {node.hint && <kbd className="acpmux-menu-hint">{node.hint}</kbd>}
      <span className="acpmux-menu-text">
        <span className="acpmux-menu-label">{node.label}</span>
      </span>
      {node.detail && <span className="acpmux-mp-detail">{node.detail}</span>}
      {node.checked && <CheckIcon />}
      {submenu && (
        <span className="acpmux-mp-chevron">
          <ChevronRightIcon />
        </span>
      )}
    </div>
  );
}
