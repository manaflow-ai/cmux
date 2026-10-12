// Settings > iPhone: the native cmux iPhone app's access to this Mac. The host lists' `phone` (the
// app's NativePhoneHost, every text localized there, live through cmux.settings.host.changed)
// draws the switch, the status, the connected phones and the pairing code; each gesture goes to
// cmux.settings.phone.run. The countdown is the only page-side state: the code's expiry ticks here.
import { useSyncExternalStore } from "react";
import { useSettingsState, useStore } from "../context";
import type { PhonePairing, PhoneState } from "../ops";
import { Switch } from "../editors/ToggleEditor";
import { ActionRow } from "./ActionRow";

const fill = (template: string, value: string) => template.replace("%@", value);

/** Whole seconds since the epoch, ticking once a second while a pairing code shows. */
function subscribeSecond(onTick: () => void): () => void {
  const timer = setInterval(onTick, 1000);
  return () => clearInterval(timer);
}
const nowSecond = () => Math.floor(Date.now() / 1000);

/** `9:41` for the time left before `expiresAt` (Unix ms); null once expired. */
export function timeLeft(expiresAt: number, nowSeconds: number): string | null {
  const left = Math.floor(expiresAt / 1000) - nowSeconds;
  if (left <= 0) return null;
  return `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;
}

export function PhoneCard() {
  const { host } = useSettingsState();
  const phone = host?.phone;
  if (!phone) return null;
  return <PhoneBody phone={phone} />;
}

function PhoneBody({ phone }: { phone: PhoneState }) {
  const store = useStore();
  const s = phone.strings;
  const run = (action: "enable" | "disable" | "pair" | "endPairing" | "reset") => void store.runPhone({ action });
  return (
    <>
      {/* No group title: the category heading above already reads "iPhone" (as Accounts). */}
      <section className="group" data-card="phone" data-phone-enabled={phone.enabled}>
        <div className="rows">
          <div className="row" tabIndex={-1}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title" id="phone-allow">
                  {s.allow}
                </div>
                <div className="row-help">{s.allow_help}</div>
              </div>
              <div className="row-control">
                <Switch
                  checked={phone.enabled}
                  disabled={false}
                  labelId="phone-allow"
                  onToggle={(next) => run(next ? "enable" : "disable")}
                />
              </div>
            </div>
          </div>
          <ActionRow title={s.status} help={phone.host_name ? fill(s.registered_as, phone.host_name) : ""}>
            <span
              className={phone.status_kind === "attention" ? "badge badge-warning" : "badge"}
              data-phone-status={phone.status_kind}
            >
              {phone.status}
            </span>
          </ActionRow>
          {phone.enabled && (
            <ActionRow title={s.pair} help={s.pair_help}>
              <button
                type="button"
                className="button"
                data-action="phone.pair"
                disabled={phone.pairing_busy}
                onClick={() => run("pair")}
              >
                {phone.pairing ? s.refresh : s.pair}
              </button>
            </ActionRow>
          )}
          {phone.can_reset && (
            <ActionRow title={s.reset} help={s.reset_help}>
              <button type="button" className="button" data-action="phone.reset" onClick={() => run("reset")}>
                {s.reset}
              </button>
            </ActionRow>
          )}
        </div>
        {phone.error && <output className="row-help block phone-error">{phone.error}</output>}
      </section>
      {phone.enabled && phone.pairing && (
        <PairingPanel
          pairing={phone.pairing}
          strings={s}
          onRefresh={() => run("pair")}
          onDone={() => run("endPairing")}
        />
      )}
      {phone.enabled && (
        <section className="group" data-card="phone-peers">
          <h3 className="group-title">{s.phones}</h3>
          {phone.peers.length === 0 ? (
            // Outside the bordered rows (as Accounts' empty state): a bare line inside them has no row padding.
            <output className="row-help block" data-phone-peers-empty="">
              {s.no_phones}
            </output>
          ) : (
            <div className="rows">
              {phone.peers.map((peer, index) => (
                <ActionRow key={peer.id} title={`iPhone ${index + 1}`} help="">
                  <span className="badge" data-phone-path={peer.path}>
                    {peer.path}
                  </span>
                </ActionRow>
              ))}
            </div>
          )}
        </section>
      )}
    </>
  );
}

function PairingPanel({
  pairing,
  strings: s,
  onRefresh,
  onDone,
}: {
  pairing: PhonePairing;
  strings: PhoneState["strings"];
  onRefresh(): void;
  onDone(): void;
}) {
  const now = useSyncExternalStore(subscribeSecond, nowSecond, nowSecond);
  const left = timeLeft(pairing.expires_at, now);
  return (
    <section className="group phone-pairing" data-card="phone-pairing">
      <div className="phone-pairing-body">
        {pairing.qr && left && <img className="phone-qr" src={pairing.qr} alt={pairing.url} width={180} height={180} />}
        <div className="phone-pairing-text">
          <div className="phone-code" data-expired={left === null}>
            {pairing.code}
          </div>
          <div className="row-help">{left ? fill(s.expires, left) : s.expired}</div>
          <div className="phone-pairing-buttons">
            <button type="button" className="button" onClick={onRefresh}>
              {s.refresh}
            </button>
            <button type="button" className="button" onClick={onDone}>
              {s.done}
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
