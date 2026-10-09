// The changes view's scope pill and menu: Last turn, then the working tree
// (Uncommitted, Unstaged, Staged), then history (Committed, Branch), the chosen one checked.
// It is a shared menu button: Base UI owns focus, typeahead, arrows, and dismissal.
import React, { useRef, useState } from "react";
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
  children?: React.ReactNode;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const focusSelected = () =>
    document.querySelector<HTMLElement>('.acpmux-scope-list [role="menuitemradio"][aria-checked="true"]')?.focus({
      preventScroll: true,
    });
  return (
    <span className="acpmux-scope-menu">
      <Menu open={open} onOpenChange={setOpen} onOpenChangeComplete={(next) => next && focusSelected()}>
        <MenuButton
          buttonRef={button}
          className="acpmux-diff-scope"
          label={t("changes.scopeButton", { scope: t(SCOPE_LABEL[scope]) })}
          aria-haspopup="menu"
        >
          <strong>{t(SCOPE_LABEL[scope])}</strong>
          <ChevronDown className="acpmux-scope-chevron" />
          {children}
        </MenuButton>
        <MenuPopup
          className="acpmux-file-menu-list acpmux-scope-list"
          aria-label={t("changes.scopeMenu")}
          finalFocus={button}
        >
          <MenuRadioGroup
            value={scope}
            onValueChange={(next) => {
              setOpen(false);
              onScope(next as ChangeScope);
            }}
          >
            {SCOPE_ORDER.map((entry, index) =>
              entry === null ? (
                <MenuSeparator key={`separator-${index}`} />
              ) : (
                <MenuRadioItem key={entry} value={entry} className="acpmux-file-menu-item">
                  <span className="acpmux-scope-label">{t(SCOPE_LABEL[entry])}</span>
                </MenuRadioItem>
              ),
            )}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}
