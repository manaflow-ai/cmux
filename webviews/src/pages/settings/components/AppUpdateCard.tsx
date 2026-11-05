// Updates > App Update: what the app update does now, from the host lists' `app_update` (the app's
// UpdaterService, live through cmux.settings.host.changed). A download runs with no sidebar card
// (Leo 2026-11-03, after ChatGPT's one-step update), so its progress and Cancel live here, and so
// does a failed check's or download's Try Again, background ones included. Every text is the host's.
import { useState } from "react";
import { Button } from "../../../ui/Button";
import { useSettingsState, useStore } from "../context";
import type { AppUpdateAction } from "../ops";
import { ActionRow } from "./ActionRow";

export function AppUpdateCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const [running, setRunning] = useState<AppUpdateAction | null>(null);
  const state = host?.app_update;
  if (!state) return null;
  const run = async (action: AppUpdateAction) => {
    setRunning(action);
    await store.runAppUpdate(action);
    setRunning(null);
  };
  const progress = state.progress;
  return (
    <section className="group" data-card="app-update" data-phase={state.phase}>
      <h3 className="group-title">{state.title}</h3>
      <div className="rows">
        <ActionRow title={state.status} help={state.detail ?? ""}>
          {state.actions.map((action) => (
            <Button
              variant={action.prominent ? "solid" : "subtle"}
              key={action.id}
              type="button"
              className={action.prominent ? "button app-update-prominent" : "button"}
              data-app-update={action.id}
              disabled={running !== null}
              onClick={() => void run(action.id)}
            >
              {action.title}
            </Button>
          ))}
        </ActionRow>
        {progress !== undefined && (
          <div className="app-update-progress-row">
            <progress
              className="app-update-progress"
              data-app-update-progress=""
              max={100}
              {...(progress === null ? {} : { value: Math.round(progress * 100) })}
              aria-label={state.status}
            />
          </div>
        )}
      </div>
    </section>
  );
}
