// A changed file's More menu: Reject file and Accept file in a turn's review, Stage or Unstage in a
// git scope, Copy path, Open file in a tab,
// and Collapse file (Expand file when folded). Shared Base UI owns the menu's
// arrows, typeahead, Escape and focus restoration.
import { More } from "../changeIcons";
import { copyText } from "../conversation/clipboard";
import { useT } from "../i18n";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";

export function FileMenu({
  path,
  name,
  collapsed,
  onToggleCollapsed,
  onOpenInTab,
  review,
  stage,
}: {
  path: string;
  name: string;
  collapsed: boolean;
  onToggleCollapsed: () => void;
  /// Absent for a file with nothing on disk to open, such as a deleted one.
  onOpenInTab?: () => void;
  /// Reject file and Accept file (cx-ncc.47), while the turn's review has changes left to decide.
  review?: { label: string; run: () => void }[];
  /// Stage or Unstage (cx-tcwj), where the scope's files can be.
  stage?: { label: string; run: () => void };
}) {
  const t = useT();
  const items = [
    ...(review ?? []),
    ...(stage ? [{ label: stage.label, run: stage.run }] : []),
    // Clipboard fallback runs after the menu has closed; it must not steal focus from a field the
    // user chooses while an async clipboard write is pending.
    { label: t("changes.copyPath"), run: () => copyText(path) },
    ...(onOpenInTab ? [{ label: t("changes.openInTab"), run: onOpenInTab }] : []),
    { label: collapsed ? t("changes.expandFile") : t("changes.collapseFile"), run: onToggleCollapsed },
  ];
  return (
    <span className="acpmux-file-menu">
      <Menu>
        <MenuButton className="acpmux-fh-btn" label={t("changes.moreActionsFor", { name })} aria-haspopup="menu">
          <More />
        </MenuButton>
        <MenuPopup className="acpmux-file-menu-list" label={t("changes.actionsFor", { name })} align="start">
          {items.map((item) => (
            <MenuItem key={item.label} className="acpmux-file-menu-item" onSelect={() => item.run()}>
              {item.label}
            </MenuItem>
          ))}
        </MenuPopup>
      </Menu>
    </span>
  );
}
