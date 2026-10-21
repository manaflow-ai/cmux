// All chats' Filter (cx-htpk0): a pill naming the chosen filter and a menu of the four, styled as
// the changes view's scope menu (the pane does not load ui.css, so Select's popup would be bare).
// Picking one closes the menu; the chosen one is checked and highlighted when it opens.
import { useId, useState } from "react";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import { ChevronDown } from "../changeIcons";
import { useNt } from "./strings";

export type ChatStatusFilter = "all" | "working" | "input" | "done";
const FILTERS = ["all", "working", "input", "done"] as const satisfies readonly ChatStatusFilter[];

export function ChatFilterMenu({
  filter,
  onFilter,
}: {
  filter: ChatStatusFilter;
  onFilter(filter: ChatStatusFilter): void;
}) {
  const nt = useNt();
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const focusSelected = () => {
    document.getElementById(menuId)?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
  };
  return (
    <span className="nt-chats-filter">
      <Menu open={open} onOpenChange={setOpen} onOpenChangeComplete={(next) => next && focusSelected()}>
        <MenuButton
          className={`nt-chats-filter-button${filter === "all" ? "" : " is-selected"}`}
          label={nt("filter.label")}
          aria-haspopup="menu"
        >
          {nt(`filter.${filter}`)}
          <ChevronDown className="nt-chats-filter-chevron" />
        </MenuButton>
        <MenuPopup
          id={menuId}
          label={nt("filter.label")}
          className="acpmux-file-menu-list acpmux-scope-list nt-chats-filter-list"
          align="start"
        >
          <MenuRadioGroup
            value={filter}
            onValueChange={(value) => {
              setOpen(false);
              onFilter(value as ChatStatusFilter);
            }}
          >
            {FILTERS.map((value) => (
              <MenuRadioItem key={value} value={value} className="acpmux-file-menu-item">
                {nt(`filter.${value}`)}
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}
