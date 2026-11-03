import { useEffect, useRef, useState } from "react";
import { Dialog } from "../../../ui/Dialog";
import { DialogButton, keyedIconProps } from "../../../ui/DialogButton";
import { contactError, contactHandle, type ChiefContactClient, type ChiefContactStatus } from "../chiefContact";
import { Icon } from "../icons";
import { t } from "../strings";
import "../chiefContact.css";

export type ContactLayout = "balanced" | "compact" | "roomy";

export function ChiefContactSheet({
  service,
  mascot,
  onClose,
  layout = "balanced",
}: {
  service: ChiefContactClient;
  mascot: string;
  onClose(): void;
  layout?: ContactLayout;
}) {
  const [status, setStatus] = useState<ChiefContactStatus>({ state: "idle" });
  const [loaded, setLoaded] = useState(false);
  const [handle, setHandle] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const generation = useRef(0);
  const inFlight = useRef(false);
  const eventRevision = useRef(0);
  const [refresh, setRefresh] = useState(0);
  useEffect(() => {
    const current = ++generation.current;
    let stop: (() => void) | undefined;
    inFlight.current = false;
    setBusy(false);
    setLoaded(false);
    setStatus({ state: "idle" });
    setError(undefined);
    const live = () => generation.current === current;
    const changed = (next: ChiefContactStatus) => {
      if (!live()) return;
      eventRevision.current++;
      setStatus(next);
      setLoaded(true);
    };
    // Install the listener before reading. A late snapshot cannot overwrite a newer event.
    void (async () => {
      try {
        const unsubscribe = await service.subscribe(changed);
        if (!live()) {
          unsubscribe();
          return;
        }
        stop = unsubscribe;
        const revision = eventRevision.current;
        const next = await service.status();
        if (live() && eventRevision.current === revision) {
          setStatus(next);
          setLoaded(true);
        }
      } catch {
        if (live()) setError("failed");
      }
    })();
    return () => {
      generation.current++;
      stop?.();
    };
  }, [service, refresh]);

  const run = async (operation: () => Promise<ChiefContactStatus>) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(undefined);
    const current = generation.current;
    const revision = eventRevision.current;
    try {
      const next = await operation();
      if (generation.current === current && eventRevision.current === revision) {
        setStatus(next);
        setLoaded(true);
      }
    } catch (failure) {
      if (generation.current === current) setError(contactError(failure));
    } finally {
      if (generation.current === current) {
        inFlight.current = false;
        setBusy(false);
      }
    }
  };
  const ready = loaded && (status.state === "idle" || status.state === "stopped");
  const send = () => {
    const address = contactHandle(handle);
    if (!address) return setError("invalid");
    if (ready) void run(() => service.request(address));
  };
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && onClose()}
      label={t("settingsPage.chiefContact.title")}
      className="chief-contact-sheet"
      initialFocus={false}
    >
      <section className="chief-contact-content" data-layout={layout}>
        <button
          type="button"
          className="chief-contact-close"
          onClick={onClose}
          {...keyedIconProps(t("settingsPage.chiefContact.close"), "escape")}
        >
          <Icon name="xmark" />
        </button>
        <img className="chief-contact-mascot" src={mascot} alt="" />
        <h2>{t("settingsPage.chiefContact.title")}</h2>
        <div className="chief-contact-channels" role="group" aria-label={t("settingsPage.chiefContact.title")}>
          {(["call", "text", "slack"] as const).map((channel) => (
            <div className="chief-contact-channel" key={channel}>
              <button
                type="button"
                disabled={channel !== "text"}
                aria-pressed={channel === "text"}
                aria-label={t(`settingsPage.chiefContact.${channel}`)}
              >
                <ChannelIcon channel={channel} />
              </button>
              <span>{t(`settingsPage.chiefContact.${channel}`)}</span>
              <small>{channel !== "text" ? t("settingsPage.chiefContact.soon") : "\u00a0"}</small>
            </div>
          ))}
        </div>
        <form
          className="chief-contact-form"
          onSubmit={(event) => {
            event.preventDefault();
            send();
          }}
        >
          <label htmlFor="chief-contact-handle">{t("settingsPage.chiefContact.handle")}</label>
          <input
            id="chief-contact-handle"
            value={handle}
            onChange={(event) => setHandle(event.target.value)}
            placeholder={t("settingsPage.chiefContact.phoneHint")}
            autoComplete="off"
            autoCapitalize="none"
            spellCheck={false}
            disabled={!ready || busy}
            aria-describedby="chief-contact-status"
          />
          <p id="chief-contact-status" className="chief-contact-status" role="status">
            {t(
              `settingsPage.chiefContact.${status.state === "waiting" ? "waiting" : status.state === "linked" ? "confirmed" : status.state === "stopped" ? "stopped" : "intro"}`,
            )}
            {status?.handle && <span className="chief-contact-address">{status.handle}</span>}
          </p>
          <p className="chief-contact-privacy">{t("settingsPage.chiefContact.privacy")}</p>
          {status.state === "linked" || status.state === "waiting" ? (
            <DialogButton
              dialogKey={null}
              disabled={busy}
              className="chief-contact-primary"
              onClick={() => void run(() => service.unlink())}
            >
              {t("settingsPage.chiefContact.disconnect")}
            </DialogButton>
          ) : !loaded && error ? (
            <DialogButton
              dialogKey={null}
              disabled={busy}
              className="chief-contact-primary"
              onClick={() => setRefresh((value) => value + 1)}
            >
              {t("settingsPage.chiefContact.retry")}
            </DialogButton>
          ) : (
            <DialogButton
              dialogKey="return"
              type="submit"
              disabled={!ready || busy || !handle.trim()}
              className="chief-contact-primary"
            >
              {t(`settingsPage.chiefContact.${busy ? "sending" : "send"}`)}
            </DialogButton>
          )}
          <p className="chief-contact-error" role="alert">
            {error ? t(`settingsPage.chiefContact.${error}`) : "\u00a0"}
          </p>
        </form>
      </section>
    </Dialog>
  );
}

function ChannelIcon({ channel }: { channel: "call" | "text" | "slack" }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {channel === "call" ? (
        <path d="m5 3 4 4-2 3a15 15 0 0 0 7 7l3-2 4 4-2 2C11 22 2 13 3 5Z" />
      ) : channel === "text" ? (
        <path d="M4 4h16v12H10l-6 4Z" />
      ) : (
        <path d="M9 3v18M15 3v18M3 9h18M3 15h18" />
      )}
    </svg>
  );
}
