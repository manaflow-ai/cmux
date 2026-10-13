// Accounts > iPhone: the cnx phone host the app runs (Packages/macOS/CmuxNext CnxHostSupervisor).
// The host sends the card as data with every text localized (`iphone` in the host lists, live
// through cmux.settings.host.changed); the switch runs cmux.settings.iphone.set.
import { useId } from "react";
import { useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { ActionRow } from "./ActionRow";
import { ResetSpacer } from "./ResetButton";

export function IPhoneCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const labelId = useId();
  const state = host?.iphone;
  if (!state) return null;
  return (
    <section className="group" data-card="iphone" data-phase={state.phase}>
      <h3 className="group-title">{state.title}</h3>
      <div className="rows">
        <div className="row" tabIndex={-1} data-iphone-allow="">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title" id={labelId}>
                {state.allow_title}
              </div>
              <div className="row-help" title={state.allow_help}>
                {state.allow_help}
              </div>
            </div>
            <div className="row-control action-row-control">
              <Switch
                checked={state.allowed}
                disabled={!state.enabled}
                labelId={labelId}
                onToggle={(next) => void store.setIPhoneAllowed(next)}
              />
              <ResetSpacer />
            </div>
          </div>
        </div>
        <ActionRow title={state.status_title} help={state.status}>
          {null}
        </ActionRow>
        <ActionRow title={state.how_title} help={state.how}>
          {null}
        </ActionRow>
      </div>
      {state.allowed && (
        <>
          <h3 className="group-title">{state.phones_title}</h3>
          <div className="rows" data-iphone-phones="">
            {state.phones.length === 0 ? (
              <div className="row">
                <div className="empty">{state.phones_empty}</div>
              </div>
            ) : (
              state.phones.map((phone) => (
                <div className="row" key={phone.id} data-iphone-phone={phone.id}>
                  <div className="row-main">
                    <div className="row-label">
                      <div className="row-title">{phone.title}</div>
                      <div className="row-help">{phone.subtitle}</div>
                    </div>
                  </div>
                </div>
              ))
            )}
          </div>
        </>
      )}
    </section>
  );
}
