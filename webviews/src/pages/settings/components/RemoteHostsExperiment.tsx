// A default-off Labs entry to the existing host-owned workspace flow. No connection is
// made by mounting this card: the native picker owns discovery, consent and connection.
import { useState } from "react";
import { Button } from "../../../ui/Button";
import { userMessage } from "../../shared/userMessage";
import { useRowState, useStore } from "../context";
import { SETTINGS_SENTENCES } from "../ops";
import { t } from "../strings";

export function RemoteHostsExperiment() {
  const store = useStore();
  const { value, connected, readable } = useRowState("labs.previewFeatures");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (value !== true) return null;

  const connect = async () => {
    setBusy(true);
    setError(null);
    try {
      const reply = await store.runAction("remote.newGroup");
      if (!reply.ok) setError(userMessage(reply.error, SETTINGS_SENTENCES));
      else if (
        typeof reply.value === "object" &&
        reply.value !== null &&
        "ran" in reply.value &&
        reply.value.ran === false
      ) {
        setError(userMessage({ code: "cmux.app.action_refused" }));
      }
    } catch (cause) {
      setError(userMessage(cause, SETTINGS_SENTENCES));
    }
    setBusy(false);
  };

  return (
    <section className="group" data-devices-group="remote-hosts">
      <h3 className="group-title">{t("settingsPage.remoteHosts.title")}</h3>
      <div className="rows">
        <div className="row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-help">{t("settingsPage.remoteHosts.help")}</div>
            </div>
            <div className="row-control">
              <Button
                type="button"
                className="button"
                data-remote-hosts-connect=""
                disabled={!connected || !readable || busy}
                onClick={() => void connect()}
              >
                {t("action.remote.newGroup")}
              </Button>
            </div>
          </div>
          {error && (
            <div className="row-help" role="alert">
              {error}
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
