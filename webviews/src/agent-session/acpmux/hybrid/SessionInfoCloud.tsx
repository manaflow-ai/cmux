// Session Info's cloud controls (RFD 0078), in the place the Remote Control row had (Leo,
// 2026-11-23: "we can replace that area with our cloud... paradigms"). Remote Control stays one
// app-wide switch in Settings; a chat no longer shows it. Rows of the Environment list: Keep
// Running (the same switch as the composer's cloud button, with the plan's slots) and, in the
// `where` look, where the chat is allowed to run.
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { Switch } from "../../../ui/Switch";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import { WithFacts } from "../chips/FactsHoverCard";
import { CloudToggle } from "./CloudToggle";
import type { HybridLook, HybridPin, HybridView } from "./hybridModel";
import "./cloudToggle.css";

const ROW_ICON = rowIconSize(12);

/// `switch`: one row, a switch (as Remote Control's was). `where`: the switch and a second row that
/// picks where the chat may run. `button`: one row whose control is the composer's cloud button.
export type SessionInfoCloudLook = "switch" | "where" | "button";

export type SessionInfoCloudControl = {
  view: HybridView;
  /// Absent while high priority has no wire: the Keep Running row is not drawn.
  setLit?(on: boolean): void;
  setPin(pin: HybridPin): void;
};

const PINS = ["local", "auto", "cloud"] as const;
const PIN_KEYS = { auto: "composer.auto", cloud: "hybrid.pin.cloud", local: "hybrid.pin.local" } as const;
// A short hint under each choice: what happens to the chat when this Mac sleeps.
const PIN_HINT_KEYS = {
  local: "hybrid.pin.local.hint",
  auto: "hybrid.pin.auto.hint",
  cloud: "hybrid.pin.cloud.hint",
} as const;

export function SessionInfoCloudRows({
  control,
  look = "where",
  toggleLook = "rainbow",
}: {
  control: SessionInfoCloudControl;
  look?: SessionInfoCloudLook;
  toggleLook?: HybridLook;
}) {
  const t = useT();
  const { view } = control;
  const on = view.lit || view.waiting === true;
  const name = t("hybrid.keepRunning");
  const help = view.waiting ? t("hybrid.waiting") : t(view.lit ? "hybrid.keepRunning.help" : "hybrid.auto.help");
  const count = t("hybrid.slots", { used: view.used, total: view.total });
  const setLit = control.setLit;
  return (
    <>
      {setLit && (
        <li className="acpmux-session-info-row acpmux-hybrid-row" data-testid="session-info-keep-running">
          <Icon name="cloud" size={ROW_ICON} row fit />
          {look === "button" ? (
            <>
              <span className="acpmux-session-info-row__name">{name}</span>
              <span className="acpmux-hybrid-row__count">{count}</span>
              <CloudToggle view={view} look={toggleLook} form="icon" onChange={setLit} />
            </>
          ) : (
            <WithFacts facts={[{ value: help }]}>
              {(facts) => (
                <label {...facts} className="acpmux-session-info-switch">
                  <span className="acpmux-session-info-row__name">{name}</span>
                  <span className="acpmux-hybrid-row__count">{count}</span>
                  <Switch
                    className="acpmux-session-info-switch__input"
                    size="md"
                    aria-label={name}
                    checked={on}
                    onCheckedChange={setLit}
                  />
                </label>
              )}
            </WithFacts>
          )}
        </li>
      )}
      {(look === "where" || !setLit) && (
        // The row itself opens the menu, as the Environment list's other action rows (the folder,
        // Share Screen) are whole-row buttons; the choice is its muted end value, as the machine
        // row's kind (cmux#56150: a ghost pill here drew WebKit's bezel, the pane has no ui.css).
        <li data-testid="session-info-runs-on">
          <Menu>
            <MenuButton
              className="acpmux-session-info-row acpmux-session-info-row--button acpmux-hybrid-row"
              data-menu="RunsOn"
            >
              <Icon name="cloud" size={ROW_ICON} row fit />
              <span className="acpmux-session-info-row__name">{t("hybrid.pin")}</span>
              <span className="acpmux-session-info-row__end acpmux-hybrid-where">{t(PIN_KEYS[view.pin])}</span>
            </MenuButton>
            {/* The row's drop-down, its end on the row's end: each choice with a short hint under
                its name, the check a trailing mark (cloudToggle.css). acpmux-picker-menu lets the
                positioner place it; bare acpmux-menu keeps the composer's absolute rule, and the
                pane's edge cut the menu off. */}
            <MenuPopup
              align="end"
              label={t("hybrid.pin")}
              className="acpmux-menu acpmux-picker-menu acpmux-hybrid-pin-menu"
            >
              <MenuRadioGroup value={view.pin} onValueChange={(next) => control.setPin(next as HybridPin)}>
                {PINS.map((pin) => (
                  <MenuRadioItem key={pin} value={pin} closeOnClick>
                    <span className="ui-menu-text">
                      <span className="ui-menu-label">{t(PIN_KEYS[pin])}</span>
                      {/* data-popup-detail: the native popup host draws a dash before it, not "AutoMoves". */}
                      <span className="ui-menu-subtitle" data-popup-detail="">
                        {t(PIN_HINT_KEYS[pin])}
                      </span>
                    </span>
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
            </MenuPopup>
          </Menu>
        </li>
      )}
    </>
  );
}
