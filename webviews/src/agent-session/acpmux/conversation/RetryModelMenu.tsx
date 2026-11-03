// Retry with another model (cx-ncc.62): the chevron beside a turn's Retry opens the chat harness's
// models, the current one checked, drawn as the composer's model menu (QuickModelMenu.tsx,
// modelPicker.css .acpmux-quick-menu): one rounded surface, a caption header, one-line rows with the
// check at the trailing edge, a model's detail ("1M context") in secondary text, and every model past
// the top ones under a More models submenu (retryModelSections.ts). Leo 2026-10-20: the menu was a
// raw list in the bare system font with models twice; the pane does not load ui.css, so a menu
// without the pane's classes draws unstyled (test/pane-menus-styled.test.ts).
import { ChevronDown } from "./icons";
import {
  Menu,
  MenuButton,
  MenuGroup,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  Submenu,
} from "../../../ui/Menu";
import { retryModelSections, type RetryModel } from "./retryModelSections";
import type { TurnActions } from "./turnActions";
import { useT } from "../i18n";

/** A row's name and its detail after " · " ("Fable 5.1 · 1M context"), the detail in secondary text.
 *  One label cell, as the composer's model menu draws it (QuickModelMenu's QuickModelLabel): a row with
 *  a check is a two-column grid (modelPicker.css), so a bare detail would fall into the 16px check
 *  column of an unchecked row and run past the menu's edge. */
function ModelName({ name }: { name: string }) {
  const [label = name, ...detail] = name.split(" · ");
  return (
    <span className="acpmux-quick-label">
      <span className="acpmux-menu-label">{label}</span>
      {detail.length > 0 && <span className="acpmux-quick-value">{detail.join(" · ")}</span>}
    </span>
  );
}

export function RetryModelMenu({
  retryWith,
  onPick,
}: {
  retryWith: NonNullable<TurnActions["retryWith"]>;
  onPick(model: string): void;
}) {
  const t = useT();
  const { latest, more } = retryModelSections(retryWith.models, retryWith.current, retryWith.harness, retryWith.top);
  const rows = (list: readonly RetryModel[]) => (
    <MenuRadioGroup value={retryWith.current ?? ""} onValueChange={onPick}>
      {list.map((model) => (
        <MenuRadioItem key={model.id} value={model.id} className="acpmux-quick-item" closeOnClick>
          <ModelName name={model.name} />
        </MenuRadioItem>
      ))}
    </MenuRadioGroup>
  );
  return (
    <Menu>
      <MenuButton
        className="cv-iconbtn cv-iconbtn--compact cv-turn-retry-menu"
        label={t("turn.retryWith")}
        title={t("turn.retryWith")}
      >
        <ChevronDown size={16} />
      </MenuButton>
      <MenuPopup label={t("turn.retryWith")} align="start" className="acpmux-quick-menu acpmux-retry-menu">
        <MenuGroup label={t("turn.retryWith")}>{rows(latest)}</MenuGroup>
        {more.length > 0 && (
          <>
            <MenuSeparator />
            <Submenu
              className="acpmux-quick-item acpmux-quick-sub"
              popupClassName="acpmux-quick-menu acpmux-quick-submenu acpmux-quick-more"
              label={<span className="acpmux-menu-label">{t("picker.moreModels")}</span>}
            >
              {rows(more)}
            </Submenu>
          </>
        )}
      </MenuPopup>
    </Menu>
  );
}
