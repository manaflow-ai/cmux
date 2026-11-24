// All chats' When (ask-b75ea23533): a pill naming how far back the list reaches and a menu of
// Any time, Past day, Past week and Past month, styled as the Filter beside it. The choice is the
// search's `since:` (chatQueryTerms.ts); a `since:` typed by hand shows as itself, nothing checked.
import { useId, useState } from "react";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import { focusRoute } from "../../../ui/focusRoute";
import { ChevronDown } from "../changeIcons";
import { useNt } from "./strings";
import { type ChatRecency, RECENCIES, customRecency, recencyOf } from "./chatQueryTerms";

export function ChatRecencyMenu({ query, onRecency }: { query: string; onRecency(recency: ChatRecency): void }) {
  const nt = useNt();
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const recency = recencyOf(query);
  const custom = customRecency(query);
  const typed = custom ? query.split(/\s+/).find((piece) => /^(?:since|after):/i.test(piece)) : undefined;
  const focusSelected = () => {
    const menu = document.getElementById(menuId);
    focusRoute(
      menu?.querySelector<HTMLElement>('[aria-checked="true"]') ??
        menu?.querySelector<HTMLElement>("[role=menuitemradio]"),
      "person",
      "the When menu opened: its chosen item",
    );
  };
  return (
    <span className="nt-chats-filter">
      <Menu open={open} onOpenChange={setOpen} onOpenChangeComplete={(next) => next && focusSelected()}>
        <MenuButton
          className={`nt-chats-filter-button${recency === "any" && !custom ? "" : " is-selected"}`}
          label={nt("when.label")}
          aria-haspopup="menu"
        >
          {typed ?? nt(`when.${recency}`)}
          <ChevronDown className="nt-chats-filter-chevron" />
        </MenuButton>
        <MenuPopup
          id={menuId}
          label={nt("when.label")}
          className="acpmux-file-menu-list acpmux-scope-list nt-chats-filter-list"
          align="start"
        >
          <MenuRadioGroup
            value={custom ? "" : recency}
            onValueChange={(value) => {
              setOpen(false);
              onRecency(value as ChatRecency);
            }}
          >
            {RECENCIES.map((value) => (
              <MenuRadioItem key={value} value={value} className="acpmux-file-menu-item">
                {nt(`when.${value}`)}
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}
