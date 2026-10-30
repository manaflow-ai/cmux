// Settings > Accounts > Cloud Environments (plans/cmux-next/cloud-environments-DESIGN.md): the team's
// environments as the app serves them (`cmux.settings.environments.state`), each with its build
// status, and Add, Build, Delete and Refresh (`cmux.settings.environments.run`). Build and Delete ask
// natively first (the host's confirmation sheet); the page only draws and forwards. The list is read
// when the card mounts and on Refresh; it does not poll.
import { useCallback, useEffect, useState } from "react";
import { useStore } from "../context";
import type { CloudEnvironmentRow, CloudEnvironmentsRun, CloudEnvironmentsState } from "../ops";
import { t } from "../strings";

const STATUS: Record<string, string> = {
  unbuilt: "settingsPage.cloudEnvironments.status.unbuilt",
  building: "settingsPage.cloudEnvironments.status.building",
  ready: "settingsPage.cloudEnvironments.status.ready",
  stale: "settingsPage.cloudEnvironments.status.stale",
  failed: "settingsPage.cloudEnvironments.status.failed",
};

export function CloudEnvironmentsCard() {
  const store = useStore();
  const [state, setState] = useState<CloudEnvironmentsState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const run = useCallback(
    async (gesture: CloudEnvironmentsRun) => {
      setBusy(true);
      try {
        const result = await store.runEnvironments(gesture);
        if (result.state) setState(result.state);
        setError(result.error);
        return result.error === null;
      } finally {
        setBusy(false);
      }
    },
    [store],
  );
  useEffect(() => {
    void run({ action: "refresh" });
  }, [run]);
  return (
    <section className="group" data-card="cloudEnvironments">
      <h3 className="group-title">{t("settingsPage.cloudEnvironments.title")}</h3>
      <p className="row-help">{t("settingsPage.cloudEnvironments.help")}</p>
      {state && !state.available ? (
        <div className="row" data-environments-unavailable="">
          <span className="row-help">{t("settingsPage.cloudEnvironments.unavailable")}</span>
        </div>
      ) : (
        <>
          <div className="rows">
            {state && state.environments.length === 0 && (
              <div className="row" data-environments-empty="">
                <span className="row-help">{t("settingsPage.cloudEnvironments.empty")}</span>
              </div>
            )}
            {state?.environments.map((row) => (
              <EnvironmentRow key={row.id} row={row} busy={busy} run={run} />
            ))}
          </div>
          <AddEnvironment busy={busy} run={run} />
          <div className="host-footer">
            <button
              type="button"
              className="button"
              data-environments="refresh"
              disabled={busy}
              onClick={() => void run({ action: "refresh" })}
            >
              {t("settingsPage.cloudEnvironments.refresh")}
            </button>
          </div>
        </>
      )}
      {(error ?? state?.error) && (
        <div className="row-error" data-environments-error="">
          {error ?? state?.error}
        </div>
      )}
    </section>
  );
}

function EnvironmentRow({
  row,
  busy,
  run,
}: {
  row: CloudEnvironmentRow;
  busy: boolean;
  run: (gesture: CloudEnvironmentsRun) => Promise<boolean>;
}) {
  const status = STATUS[row.status];
  return (
    <div className="row" data-environment={row.id}>
      <span className="row-label">
        <span className="row-title">{row.name}</span>
        <span className="row-help" data-environment-status={row.status}>
          {" "}
          {status ? t(status) : row.status}
          {row.repo ? ` · ${row.repo}` : ""}
        </span>
        {row.error && <span className="row-help"> {row.error}</span>}
        {row.log_tail && (
          <details data-environment-log="">
            <summary>{t("settingsPage.cloudEnvironments.logTail")}</summary>
            <pre>{row.log_tail}</pre>
          </details>
        )}
      </span>
      <span className="row-control">
        <button
          type="button"
          className="button"
          data-environment-action="build"
          disabled={busy || row.status === "building" || row.status === "ready"}
          onClick={() => void run({ action: "build", id: row.id })}
        >
          {t("settingsPage.cloudEnvironments.build")}
        </button>
        <button
          type="button"
          className="button"
          data-environment-action="delete"
          disabled={busy || row.status === "building"}
          onClick={() => void run({ action: "delete", id: row.id })}
        >
          {t("settingsPage.cloudEnvironments.delete")}
        </button>
      </span>
    </div>
  );
}

function AddEnvironment({ busy, run }: { busy: boolean; run: (gesture: CloudEnvironmentsRun) => Promise<boolean> }) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [repo, setRepo] = useState("");
  const [setup, setSetup] = useState("");
  if (!open) {
    return (
      <div className="host-footer">
        <button type="button" className="button" data-environments="add" disabled={busy} onClick={() => setOpen(true)}>
          {t("settingsPage.cloudEnvironments.add")}
        </button>
      </div>
    );
  }
  const save = async () => {
    if (await run({ action: "save", name: name.trim(), repo: repo.trim(), setup_script: setup })) {
      setOpen(false);
      setName("");
      setRepo("");
      setSetup("");
    }
  };
  return (
    <div className="host-form" data-environments-form="">
      <label className="host-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.name")}</span>
        <input
          className="field"
          data-environment-field="name"
          aria-label={t("settingsPage.cloudEnvironments.name")}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </label>
      <label className="host-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.repo")}</span>
        <input
          className="field"
          data-environment-field="repo"
          aria-label={t("settingsPage.cloudEnvironments.repo")}
          placeholder="owner/name"
          value={repo}
          onChange={(e) => setRepo(e.target.value)}
        />
      </label>
      <label className="host-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.setup")}</span>
        <input
          className="field"
          data-environment-field="setup"
          aria-label={t("settingsPage.cloudEnvironments.setup")}
          placeholder="bun install"
          value={setup}
          onChange={(e) => setSetup(e.target.value)}
        />
      </label>
      <button type="button" className="button" data-environments="save" disabled={busy} onClick={() => void save()}>
        {t("settingsPage.cloudEnvironments.save")}
      </button>
    </div>
  );
}
