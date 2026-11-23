// Session Info's cloud controls (RFD 0075), in the place the Remote Control row had (Leo,
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

const PINS = ["auto", "cloud", "local"] as const;
const PIN_KEYS = { auto: "hybrid.mode.hybrid", cloud: "hybrid.pin.cloud", local: "hybrid.pin.local" } as const;

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
        <li className="acpmux-session-info-row acpmux-hybrid-row" data-testid="session-info-runs-on">
          <Icon name="cloud" size={ROW_ICON} row fit />
          <span className="acpmux-session-info-row__name">{t("hybrid.pin")}</span>
          <Menu>
            <MenuButton className="acpmux-hybrid-where ui-ghost ui-ghost-sm" data-menu="RunsOn">
              {t(PIN_KEYS[view.pin])}
            </MenuButton>
            <MenuPopup align="end" label={t("hybrid.pin")} className="acpmux-menu">
              <MenuRadioGroup value={view.pin} onValueChange={(next) => control.setPin(next as HybridPin)}>
                {PINS.map((pin) => (
                  <MenuRadioItem key={pin} value={pin} closeOnClick>
                    {t(PIN_KEYS[pin])}
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
