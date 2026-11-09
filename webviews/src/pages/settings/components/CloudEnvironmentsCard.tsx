// Settings > Accounts > Cloud Environments (plans/cmux-next/cloud-environments-DESIGN.md): the team's
// environments as the app serves them (`cmux.settings.environments.state`), each with its build
// status, and Add, Edit, Build, Delete and Refresh (`cmux.settings.environments.run`). Build and Delete
// ask natively first (the host's confirmation sheet); the page only draws and forwards. The list is read
// when the card mounts and on Refresh; it does not poll. Add and Edit share one form, like the Codex desktop
// app's environment editor (Leo, 2026-11-09: "as for cloud, how about configuring
// "environments" or whatever that stuff is in chatgpt desktop app"): name, repository, a multi-line
// setup script and variables, each a plain value or a vault secret's name.
import { useCallback, useEffect, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Select } from "../../../ui/Select";
import { useStore } from "../context";
import type {
  CloudEnvironmentRow,
  CloudEnvironmentsRun,
  CloudEnvironmentsState,
  CloudEnvironmentVariable,
} from "../ops";
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
            <Button
              type="button"
              className="button"
              data-environments="refresh"
              disabled={busy}
              onClick={() => void run({ action: "refresh" })}
            >
              {t("settingsPage.cloudEnvironments.refresh")}
            </Button>
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

type Run = (gesture: CloudEnvironmentsRun) => Promise<boolean>;

function EnvironmentRow({ row, busy, run }: { row: CloudEnvironmentRow; busy: boolean; run: Run }) {
  const status = STATUS[row.status];
  // The row as Edit opened it: Save sends only what the person changed from this, so a refresh
  // that brings a teammate's edit in while the form is open never sends the old values back.
  const [editing, setEditing] = useState<CloudEnvironmentRow | null>(null);
  return (
    <div className="row" data-environment={row.id}>
      <div className="row-main">
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
          <Button
            type="button"
            className="button"
            data-environment-action="edit"
            disabled={busy || editing !== null}
            onClick={() => setEditing(row)}
          >
            {t("settingsPage.cloudEnvironments.edit")}
          </Button>
          <Button
            type="button"
            className="button"
            data-environment-action="build"
            disabled={busy || row.status === "building" || row.status === "ready"}
            onClick={() => void run({ action: "build", id: row.id })}
          >
            {t("settingsPage.cloudEnvironments.build")}
          </Button>
          <Button
            type="button"
            className="button"
            data-environment-action="delete"
            disabled={busy || row.status === "building"}
            onClick={() => void run({ action: "delete", id: row.id })}
          >
            {t("settingsPage.cloudEnvironments.delete")}
          </Button>
        </span>
      </div>
      {editing !== null && (
        <EnvironmentForm
          row={editing}
          busy={busy}
          onSave={async (draft) => {
            if (await run(editRun(editing, draft))) setEditing(null);
          }}
          onCancel={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function AddEnvironment({ busy, run }: { busy: boolean; run: Run }) {
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <div className="host-footer">
        <Button type="button" className="button" data-environments="add" disabled={busy} onClick={() => setOpen(true)}>
          {t("settingsPage.cloudEnvironments.add")}
        </Button>
      </div>
    );
  }
  return (
    <EnvironmentForm
      busy={busy}
      onSave={async (draft) => {
        const env = draft.env.filter((variable) => variable.name);
        const saved = await run({
          action: "save",
          name: draft.name,
          repo: draft.repo,
          setup_script: draft.setup_script,
          ...(env.length > 0 ? { env } : {}),
        });
        if (saved) setOpen(false);
      }}
      onCancel={() => setOpen(false)}
    />
  );
}

/** What the form holds: the fields of `cloud.environment.set`, trimmed on Save. */
export type EnvironmentDraft = {
  name: string;
  repo: string;
  setup_script: string;
  env: CloudEnvironmentVariable[];
};

const variableValue = (variable: CloudEnvironmentVariable) => ("secret" in variable ? variable.secret : variable.value);

const sameEnv = (a: CloudEnvironmentVariable[], b: CloudEnvironmentVariable[]) =>
  JSON.stringify(a) === JSON.stringify(b);

/** An edit's Save names only what changed from `row` (the environment as Edit opened it): a rename
 * alone leaves the built snapshot fresh, and a teammate's newer edit to another field stays. */
export function editRun(row: CloudEnvironmentRow, draft: EnvironmentDraft): CloudEnvironmentsRun {
  const env = draft.env.filter((variable) => variable.name);
  return {
    action: "save",
    id: row.id,
    ...(draft.name !== row.name ? { name: draft.name } : {}),
    ...(draft.repo !== (row.repo ?? "") ? { repo: draft.repo } : {}),
    ...(draft.setup_script !== row.setup_script ? { setup_script: draft.setup_script } : {}),
    ...(sameEnv(env, row.env ?? []) ? {} : { env }),
  };
}

/** The Add and Edit form: name, repository, the setup script on its own lines, and the variables. */
export function EnvironmentForm({
  row,
  busy,
  onSave,
  onCancel,
}: {
  row?: CloudEnvironmentRow;
  busy: boolean;
  onSave: (draft: EnvironmentDraft) => void | Promise<void>;
  onCancel: () => void;
}) {
  const [name, setName] = useState(row?.name ?? "");
  const [repo, setRepo] = useState(row?.repo ?? "");
  const [setup, setSetup] = useState(row?.setup_script ?? "");
  const [env, setEnv] = useState<CloudEnvironmentVariable[]>(row?.env ?? []);
  const setVariable = (index: number, next: CloudEnvironmentVariable) =>
    setEnv((rows) => rows.map((variable, at) => (at === index ? next : variable)));
  const kinds = [
    { value: "value", label: t("settingsPage.cloudEnvironments.variableValue") },
    { value: "secret", label: t("settingsPage.cloudEnvironments.variableSecret") },
  ];
  return (
    <div className="host-form environment-form" data-environments-form={row?.id ?? "new"}>
      <label className="host-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.name")}</span>
        <Input
          className="field"
          data-environment-field="name"
          aria-label={t("settingsPage.cloudEnvironments.name")}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </label>
      <label className="host-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.repo")}</span>
        <Input
          className="field"
          data-environment-field="repo"
          aria-label={t("settingsPage.cloudEnvironments.repo")}
          placeholder="owner/name"
          value={repo}
          onChange={(e) => setRepo(e.target.value)}
        />
      </label>
      <label className="environment-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.setup")}</span>
        <textarea
          className="field environment-script font-mono"
          data-environment-field="setup"
          aria-label={t("settingsPage.cloudEnvironments.setup")}
          placeholder="bun install"
          rows={4}
          spellCheck={false}
          value={setup}
          onChange={(e) => setSetup(e.target.value)}
        />
      </label>
      <div className="environment-field" data-environment-variables="">
        <span className="row-help">{t("settingsPage.cloudEnvironments.variables")}</span>
        {env.map((variable, index) => (
          <div className="environment-variable" data-environment-variable={index} key={index}>
            <Input
              className="field font-mono"
              data-variable-field="name"
              aria-label={t("settingsPage.cloudEnvironments.name")}
              placeholder="NAME"
              value={variable.name}
              onChange={(e) => setVariable(index, { ...variable, name: e.target.value })}
            />
            <Select
              className="environment-variable-kind"
              label={t("settingsPage.cloudEnvironments.variables")}
              value={"secret" in variable ? "secret" : "value"}
              options={kinds}
              closeOnPick
              onChange={(kind) =>
                setVariable(
                  index,
                  kind === "secret"
                    ? { name: variable.name, secret: variableValue(variable) }
                    : { name: variable.name, value: variableValue(variable) },
                )
              }
            />
            <Input
              className="field font-mono"
              data-variable-field="value"
              aria-label={
                "secret" in variable
                  ? t("settingsPage.cloudEnvironments.variableSecret")
                  : t("settingsPage.cloudEnvironments.variableValue")
              }
              placeholder={"secret" in variable ? "openai" : ""}
              value={variableValue(variable)}
              onChange={(e) =>
                setVariable(
                  index,
                  "secret" in variable
                    ? { name: variable.name, secret: e.target.value }
                    : { name: variable.name, value: e.target.value },
                )
              }
            />
            <Button
              type="button"
              className="button"
              data-variable-action="remove"
              onClick={() => setEnv((rows) => rows.filter((_, at) => at !== index))}
            >
              {t("settingsPage.remove")}
            </Button>
          </div>
        ))}
        <span>
          <Button
            type="button"
            className="button"
            data-environment-action="add-variable"
            onClick={() => setEnv((rows) => [...rows, { name: "", value: "" }])}
          >
            {t("settingsPage.cloudEnvironments.addVariable")}
          </Button>
        </span>
      </div>
      <div className="host-actions">
        <Button
          type="button"
          className="button"
          data-environments="save"
          disabled={busy || !name.trim()}
          onClick={() =>
            void onSave({
              name: name.trim(),
              repo: repo.trim(),
              setup_script: setup,
              env: env.map((variable) => ({ ...variable, name: variable.name.trim() })),
            })
          }
        >
          {t("settingsPage.cloudEnvironments.save")}
        </Button>
        <Button type="button" className="button" data-environments="cancel" disabled={busy} onClick={onCancel}>
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </div>
  );
}
