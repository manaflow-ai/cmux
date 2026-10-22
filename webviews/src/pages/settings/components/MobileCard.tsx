// Settings > Mobile: the iPhone host the app runs (Packages/macOS/CmuxNext MobileHostSupervisor).
// The switch is the schema row mobile.allowIPhoneConnections above this card; the card is the
// host's live state (`iphone` in the host lists, through cmux.settings.host.changed), every text
// localized by the host. Room for more mobile parts goes here.
import { useSettingsState, useStore } from "../context";
import { ActionRow } from "./ActionRow";

export function MobileCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const state = host?.iphone;
  if (!state) return null;
  return (
    <section className="group" data-card="mobile" data-phase={state.phase}>
      <h3 className="group-title">{state.title}</h3>
      <div className="rows">
        <ActionRow title={state.status_title} help={state.status}>
          {state.phase === "removed" && state.allow_again_title ? (
            <button type="button" className="button" data-allow-again="" onClick={() => void store.allowPhonesAgain()}>
              {state.allow_again_title}
            </button>
          ) : null}
        </ActionRow>
        {state.account !== null && (
          <ActionRow title={state.account_title} help={state.account}>
            {null}
          </ActionRow>
        )}
        {state.space !== null && (
          <ActionRow title={state.space_title} help={state.space}>
            {null}
          </ActionRow>
        )}
        <ActionRow title={state.how_title} help={state.how}>
          {null}
        </ActionRow>
      </div>
      {state.allowed && (state.pending?.length ?? 0) > 0 && (
        <>
          <h3 className="group-title">{state.pending_title}</h3>
          <div className="rows" data-mobile-pending="">
            {state.pending?.map((request) => (
              <div className="row" key={request.id} data-pair-request={request.id}>
                <div className="row-main">
                  <div className="row-label">
                    <div className="row-title">{request.title}</div>
                    <div className="row-help">{request.subtitle}</div>
                  </div>
                  <div className="row-control action-row-control">
                    <button
                      type="button"
                      className="button"
                      data-pair-deny={request.id}
                      onClick={() => void store.answerPair(request.id, false)}
                    >
                      {state.pair_deny_title}
                    </button>
                    <button
                      type="button"
                      className="button"
                      data-pair-allow={request.id}
                      onClick={() => void store.answerPair(request.id, true)}
                    >
                      {state.pair_allow_title}
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
      {(state.allowed || state.phones.length > 0) && (
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
                  data-connected={phone.connected ? "true" : "false"}
                  data-transport={phone.transport ?? undefined}
                  data-path={phone.path ?? undefined}
                >
                  <div className="row-main">
                    <div className="row-label">
                      <div className="row-title">{phone.title}</div>
                      <div className="row-help">{phone.subtitle}</div>
                    </div>
                    {phone.removable && (
                      <div className="row-control action-row-control">
                        <button
                          type="button"
                          className="button"
                          aria-label={`${state.remove_title} ${phone.title}`}
                          data-remove-phone={phone.id}
                          onClick={() => void store.removePhone(phone.id)}
                        >
                          {state.remove_title}
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              ))
            )}
            {state.blocked && (
              <ActionRow title={state.blocked} help={state.blocked_help ?? ""}>
                {null}
              </ActionRow>
            )}
            {state.phones_error && (
              <div className="row">
                <output className="row-help block" data-mobile-error="">
                  {state.phones_error}
                </output>
              </div>
            )}
          </div>
        </>
      )}
    </section>
  );
}
