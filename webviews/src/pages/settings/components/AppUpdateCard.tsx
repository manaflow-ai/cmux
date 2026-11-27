// Updates > App Update: what the app update does now, from the host lists' `app_update` (the app's
// UpdaterService, live through cmux.settings.host.changed). A download runs with no sidebar card
// (Leo 2026-11-03, after ChatGPT's one-step update), so its progress and Cancel live here, and so
// does a failed check's or download's Try Again, background ones included. Under them, Go Back to
// Previous Build names the build this Mac kept (PreviousBuildRow). Every text is the host's.
// retry-prompt-ok: the host (UpdaterService) owns these actions; a download's Try Again installs an update.
import { useEffect, useState } from "react";
import { Button } from "../../../ui/Button";
import { useRowState, useSettingsState, useStore } from "../context";
import type { AppUpdateAction, PreviousBuild } from "../ops";
import { ActionRow } from "./ActionRow";
import { PreviousBuildRow } from "./PreviousBuildRow";
import { LOAD_FADE_CLASS, useLoadFade } from "../../../agent-session/shared/loadFade";

export function AppUpdateCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const [running, setRunning] = useState<AppUpdateAction | null>(null);
  const state = host?.app_update;
  const [previous, setPrevious] = useState<PreviousBuild | null>(null);
  // Default-off Labs row (labs.previousBuild): off, the card reads no kept build and shows no row.
  const previousOn = useRowState("labs.previousBuild").value === true;
  const shown = Boolean(state) && previousOn;
  // Read on demand when the card shows: the host checks the kept build the rollback would take.
  useEffect(() => {
    if (!shown) return;
    let live = true;
    void store.previousBuild().then((next) => {
      if (live) setPrevious(next);
    });
    return () => {
      live = false;
    };
  }, [store, shown]);
  // The card arrives with the host's lists: after a blank first paint it fades in (shared/loadFade.ts).
  const fade = useLoadFade(Boolean(state));
  if (!state) return null;
  const run = async (action: AppUpdateAction) => {
    setRunning(action);
    await store.runAppUpdate(action);
    setRunning(null);
  };
  const progress = state.progress;
  return (
    <section className={fade ? `group ${LOAD_FADE_CLASS}` : "group"} data-card="app-update" data-phase={state.phase}>
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
        {previousOn && previous && (
          <PreviousBuildRow
            previous={previous}
            busy={running !== null}
            onGoBack={(build) => store.goBackToPreviousBuild(build)}
          />
        )}
        {state.schedule?.map((line) => (
          <ActionRow key={line.id} title={line.label} help="">
            <span className="text-detail text-muted" data-app-update-schedule={line.id}>
              {line.value}
            </span>
          </ActionRow>
        ))}
      </div>
    </section>
  );
}
