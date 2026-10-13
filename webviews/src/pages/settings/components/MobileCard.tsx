// Settings > Mobile: the cnx phone host the app runs (Packages/macOS/CmuxNext CnxHostSupervisor).
// The switch is the schema row mobile.allowIPhoneConnections above this card; the card is the
// host's live state (`iphone` in the host lists, through cmux.settings.host.changed), every text
// localized by the host. Room for more mobile parts goes here.
import { useSettingsState } from "../context";
import { ActionRow } from "./ActionRow";

export function MobileCard() {
  const { host } = useSettingsState();
  const state = host?.iphone;
  if (!state) return null;
  return (
    <section className="group" data-card="mobile" data-phase={state.phase}>
      <h3 className="group-title">{state.title}</h3>
      <div className="rows">
        <ActionRow title={state.status_title} help={state.status}>
          {null}
        </ActionRow>
        {state.space !== null && (
          <ActionRow title={state.space_title} help={state.space}>
            {null}
          </ActionRow>
        )}
        <ActionRow title={state.how_title} help={state.how}>
          {null}
        </ActionRow>
      </div>
      {state.allowed && (
        <>
          <h3 className="group-title">{state.phones_title}</h3>
          <div className="rows" data-mobile-phones="">
            {state.phones.length === 0 ? (
              <div className="row">
                <div className="empty">{state.phones_empty}</div>
              </div>
            ) : (
              state.phones.map((phone) => (
                <div
                  className="row"
                  key={phone.id}
                  data-mobile-phone={phone.id}
                  data-transport={phone.transport}
                  data-path={phone.path}
                >
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
