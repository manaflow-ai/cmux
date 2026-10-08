// The changes view's scope pill and menu: Last turn, then the working tree
// (Uncommitted, Unstaged, Staged), then history (Committed, Branch), the chosen one checked.
// Base UI owns direction-aware arrows, typeahead, Escape and focus restoration. The selected
// scope is restored as the initial highlight whenever the menu opens.
import { useId, useState, type ReactNode } from "react";
import { ChevronDown } from "../changeIcons";
import { SCOPE_LABEL, SCOPE_ORDER, type ChangeScope } from "./model";
import { useT } from "../i18n";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../../ui/Menu";

export function ScopeMenu({
  scope,
  onScope,
  children,
}: {
  scope: ChangeScope;
  onScope: (scope: ChangeScope) => void;
  /// Shown in the pill after the scope's name: its totals.
  children?: ReactNode;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const focusSelected = () => {
    document.getElementById(menuId)?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
  };
  return (
    <span className="acpmux-scope-menu">
      <Menu
        open={open}
        onOpenChange={setOpen}
        onOpenChangeComplete={(next) => next && focusSelected()}
      >
        <MenuButton
          className="acpmux-diff-scope"
          label={t("changes.scopeButton", { scope: t(SCOPE_LABEL[scope]) })}
          aria-haspopup="menu"
        >
          <strong>{t(SCOPE_LABEL[scope])}</strong>
          <ChevronDown className="acpmux-scope-chevron" />
          {children}
        </MenuButton>
        <MenuPopup
          id={menuId}
          label={t("changes.scopeMenu")}
          className="acpmux-file-menu-list acpmux-scope-list"
          align="start"
        >
          <MenuRadioGroup
            value={scope}
            onValueChange={(value) => {
              setOpen(false);
              onScope(value as ChangeScope);
            }}
          >
            {SCOPE_ORDER.map((entry, index) =>
              entry === null ? (
                <MenuSeparator key={`separator-${index}`} />
              ) : (
                <MenuRadioItem
                  key={entry}
                  value={entry}
                  className="acpmux-file-menu-item"
                >
                  {t(SCOPE_LABEL[entry])}
                </MenuRadioItem>
              ),
            )}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}
