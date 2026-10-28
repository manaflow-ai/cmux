// Settings > Accounts > This Mac on Your Tailnet (Labs): the daemon's own tailnet node, reachable
// from the person's other devices as one more machine (Packages/macOS/CmuxNext TailnetNodeService).
// Sign in the way Tailscale's apps do (the host opens the sign-in link in the browser), then the
// address with Copy and Pair (a QR code and the `cmux host join` line with a single-use pairing
// ticket), and who may connect (owner-only for now: the switch is disabled until the node reads
// it). Every text comes localized from the host; `tailnet` is null while Labs is off.
import { useId } from "react";
import { useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { ActionRow } from "./ActionRow";
import { ResetSpacer } from "./ResetButton";

export function TailnetCard() {
  const store = useStore();
  const state = useSettingsState().host?.tailnet;
  const limitId = useId();
  if (!state) return null;
  const button = (title: string, action: Parameters<typeof store.tailnet>[0], attr: string) => (
    <button
      type="button"
      className="button"
      disabled={state.busy}
      {...{ [`data-tailnet-${attr}`]: "" }}
      onClick={() => void store.tailnet(action)}
    >
      {title}
    </button>
  );
  return (
    <section className="group" data-card="tailnet" data-phase={state.phase}>
      <h3 className="group-title">{state.title}</h3>
      <div className="rows">
        <ActionRow title={state.status_title} help={state.status}>
          {(state.phase === "signed_out" || state.phase === "failed") &&
            button(state.sign_in_title, "sign_in", "sign-in")}
          {state.phase === "waiting" && (
            <>
              {button(state.cancel_title, "cancel", "cancel")}
              {button(state.reopen_title, "sign_in", "reopen")}
            </>
          )}
          {state.phase === "signed_in" && button(state.sign_out_title, "sign_out", "sign-out")}
        </ActionRow>
        {state.phase === "signed_in" && state.address && (
          <div className="row" tabIndex={-1} data-tailnet-address={state.address}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">{state.address_title}</div>
                <div className="row-help selectable">{state.address}</div>
              </div>
              <div className="row-control action-row-control">
                {button(state.copy_title, "copy_address", "copy")}
                {button(state.pair_title, "pair", "pair")}
                <ResetSpacer />
              </div>
            </div>
          </div>
        )}
        {state.pair && (
          <div className="row" data-tailnet-pair-code="">
            <div className="row-main">
              <div className="row-label">
                {state.pair.qr && (
                  <img
                    src={state.pair.qr}
                    alt=""
                    width={176}
                    height={176}
                    style={{ imageRendering: "pixelated", borderRadius: 8 }}
                  />
                )}
                <code className="row-help selectable" data-tailnet-pair-command="">
                  {state.pair.command}
                </code>
                <div className="row-help">{state.pair.help}</div>
              </div>
              <div className="row-control action-row-control">
                {button(state.done_title, "close_pair", "done")}
                <ResetSpacer />
              </div>
            </div>
          </div>
        )}
        {state.phase !== "unavailable" && (
          <div className="row" tabIndex={-1}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title" id={limitId}>
                  {state.limit_title}
                </div>
                <div className="row-help">{state.limit_help}</div>
              </div>
              <div className="row-control">
                <Switch
                  checked={state.limited}
                  disabled={!state.limit_editable || state.busy}
                  labelId={limitId}
                  onToggle={() => undefined}
                />
                <ResetSpacer />
              </div>
            </div>
          </div>
        )}
        {state.error && (
          <div className="row">
            <output className="row-help block" data-tailnet-error="">
              {state.error}
            </output>
          </div>
        )}
      </div>
    </section>
  );
}
