// Settings > Automations: Cloud automations (cmux platform /v1/automations), as the bundled
// `cmux autocloud overview --json` shapes them (SettingsAutomationsCloud in the app; cmux-tui
// cli/autocloud.rs writes every summary, status, time and preview this card shows, and checks every
// spec). The list with each automation's trigger, last run and on/off switch; the form (a GitHub
// event on a repository, a webhook or a schedule; conditions over the event; the agent's repository,
// branch, harness and prompt with a preview against a sample event; limits); a run log; and the
// template gallery. Nothing changes without a click. A new webhook's secret shows once and is
// dropped from the page when the person says they saved it.
import { useCallback, useEffect, useId, useRef, useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useRowState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import type {
  AutocloudAction,
  AutocloudAnswer,
  AutocloudAutomation,
  AutocloudCatalog,
  AutocloudCondition,
  AutocloudPreview,
  AutocloudRun,
  AutocloudSpec,
  AutocloudState,
  AutocloudTemplate,
} from "../ops";
import { t } from "../strings";

const SELECT_CLASS =
  "box-border h-7 rounded-md border border-solid border-edge bg-transparent px-2 font-[inherit] text-control text-fg outline-none focus:border-accent-soft";

/** A run's tone as the status dot Settings > Devices draws. */
const TONE = {
  good: "success",
  warn: "attention",
  bad: "attention",
  plain: "neutral",
} as const;

type Act = (action: Exclude<AutocloudAction, { action: "refresh" }>) => Promise<AutocloudAnswer>;

/** The spec an empty New automation starts from. */
function blankSpec(): AutocloudSpec {
  return {
    name: "",
    trigger: { type: "github", events: ["ci_failure"], repository: "" },
    conditions: [],
    action: {
      type: "start_agent",
      repo: "",
      ref: "",
      harness: "claude",
      prompt: "",
      postBack: "comment",
    },
    guardrails: {
      cooldownSeconds: 600,
      maxRunsPerDay: 20,
      maxConcurrent: 1,
      maxMinutesPerRun: 30,
    },
  };
}

function Status({ run }: { run: Pick<AutocloudRun, "tone" | "statusLabel"> }) {
  return (
    <span className="accounts-status devices-status" data-tone={TONE[run.tone]}>
      <span className="accounts-dot" aria-hidden="true" />
      {run.statusLabel}
    </span>
  );
}

function AutomationRow({
  row,
  busy,
  act,
  onEdit,
  onRuns,
}: {
  row: AutocloudAutomation;
  busy: boolean;
  act: Act;
  onEdit: () => void;
  onRuns: () => void;
}) {
  const titleId = useId();
  const [confirming, setConfirming] = useState(false);
  const confirmTitle = t("settingsWindow.autocloud.removeTitle", row.name);
  return (
    <div className="row accounts-row" data-autocloud-automation={row.id} data-autocloud-trigger={row.triggerType ?? ""}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {row.name}
          </div>
          <div className="row-help selectable">{row.triggerText}</div>
          {row.conditionsText && <div className="row-help selectable">{row.conditionsText}</div>}
          <div className="row-help">
            {row.actionText}
            {" · "}
            <span data-autocloud-last-run={row.lastRun?.status ?? "never"}>{row.lastRunText}</span>
          </div>
        </div>
        <span className="row-control">
          <Switch
            checked={row.enabled}
            disabled={busy}
            labelId={titleId}
            onToggle={(enabled) => void act({ action: "toggle", id: row.id, enabled })}
          />
        </span>
      </div>
      {confirming ? (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" data-autocloud-confirm="" role="group" aria-label={confirmTitle}>
          <div className="row-title">{confirmTitle}</div>
          <div className="row-help">{t("settingsWindow.autocloud.removeBody")}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-autocloud-action="confirmRemove"
              disabled={busy}
              onClick={() => {
                setConfirming(false);
                void act({ action: "remove", id: row.id });
              }}
            >
              {t("settingsWindow.autocloud.remove")}
            </Button>
            <Button className="button" data-autocloud-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsWindow.autocloud.cancel")}
            </Button>
          </div>
        </div>
      ) : (
        <div className="accounts-buttons hub-actions">
          <Button
            className="button"
            data-autocloud-action="edit"
            aria-describedby={titleId}
            disabled={busy}
            onClick={onEdit}
          >
            {t("settingsWindow.autocloud.edit")}
          </Button>
          <Button className="button" data-autocloud-action="runs" aria-describedby={titleId} onClick={onRuns}>
            {t("settingsWindow.autocloud.runs")}
          </Button>
          <Button
            danger
            variant="ghost"
            className="button"
            data-autocloud-action="remove"
            aria-describedby={titleId}
            disabled={busy}
            onClick={() => setConfirming(true)}
          >
            {t("settingsWindow.autocloud.remove")}
          </Button>
        </div>
      )}
    </div>
  );
}

function RunLog({ name, runs, onClose }: { name: string; runs: AutocloudRun[] | null; onClose: () => void }) {
  return (
    <section className="group" data-autocloud-group="runs">
      <div className="group-title">{t("settingsWindow.autocloud.runLog.title", name)}</div>
      {runs === null ? (
        <div className="row-help">{t("settingsWindow.autocloud.checking")}</div>
      ) : runs.length === 0 ? (
        <div className="row-help" data-autocloud-empty="runs">
          {t("settingsWindow.autocloud.runLog.empty")}
        </div>
      ) : (
        <div className="rows">
          {runs.map((run, index) => (
            <div className="row accounts-row" key={run.id ?? index} data-autocloud-run={run.status}>
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title selectable">{run.eventText}</div>
                  <div className="row-help">
                    {[run.whenText, run.minutesText, run.machine].filter((part): part is string => !!part).join(" · ")}
                  </div>
                  {run.matchedText && <div className="row-help selectable">{run.matchedText}</div>}
                  {run.errorText && <div className="row-error selectable">{run.errorText}</div>}
                  {run.links.length > 0 && (
                    <div className="row-help">
                      {run.links.map((link, i) => (
                        <span key={link.url}>
                          {i > 0 && " · "}
                          <a href={link.url} target="_blank" rel="noreferrer" data-autocloud-link={link.label}>
                            {link.label}
                          </a>
                        </span>
                      ))}
                    </div>
                  )}
                </div>
                <span className="row-control">
                  <Status run={run} />
                </span>
              </div>
            </div>
          ))}
        </div>
      )}
      <div className="accounts-header hub-below">
        <Button className="button" data-autocloud-action="closeRuns" onClick={onClose}>
          {t("settingsWindow.autocloud.runLog.close")}
        </Button>
      </div>
    </section>
  );
}

/** A new webhook's URL and secret, once. "I saved it" drops the secret from the page for good. */
function SecretOnce({
  url,
  secret,
  text,
  onDone,
}: {
  url: string | null;
  secret: string;
  text?: string;
  onDone: () => void;
}) {
  const copy = (value: string) => void navigator.clipboard?.writeText(value);
  return (
    <section className="group" data-autocloud-group="secret">
      <div className="group-title">{t("settingsWindow.autocloud.secret.title")}</div>
      {text && <div className="row-help">{text}</div>}
      <div className="rows">
        {url && (
          <div className="row accounts-row">
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">{t("settingsWindow.autocloud.form.webhookUrl")}</div>
                <div className="row-help selectable" data-autocloud-webhook-url="">
                  {url}
                </div>
              </div>
              <span className="row-control">
                <Button className="button" data-autocloud-action="copyUrl" onClick={() => copy(url)}>
                  {t("settingsWindow.autocloud.secret.copy")}
                </Button>
              </span>
            </div>
          </div>
        )}
        <div className="row accounts-row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("settingsWindow.autocloud.secret.secret")}</div>
              <div className="row-help selectable" data-autocloud-secret="">
                <code>{secret}</code>
              </div>
            </div>
            <span className="row-control">
              <Button className="button" data-autocloud-action="copySecret" onClick={() => copy(secret)}>
                {t("settingsWindow.autocloud.secret.copy")}
              </Button>
            </span>
          </div>
        </div>
      </div>
      <div className="accounts-header hub-below">
        <Button variant="solid" className="button" data-autocloud-action="secretDone" onClick={onDone}>
          {t("settingsWindow.autocloud.secret.done")}
        </Button>
      </div>
    </section>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="row-help autocloud-field">
      <span>{label}</span>
      {children}
    </label>
  );
}

/** The operators that take no value (the platform's `exists` and `missing`). */
const VALUELESS_OPS = new Set(["exists", "missing"]);

function ConditionRow({
  condition,
  catalog,
  onChange,
  onRemove,
}: {
  condition: AutocloudCondition;
  catalog: AutocloudCatalog;
  onChange: (next: AutocloudCondition) => void;
  onRemove: () => void;
}) {
  const value = Array.isArray(condition.value) ? condition.value.join(", ") : (condition.value ?? "");
  return (
    <div className="accounts-buttons autocloud-condition" data-autocloud-condition="">
      <Input
        className="field"
        spellCheck={false}
        aria-label={t("settingsWindow.autocloud.form.path")}
        placeholder={t("settingsWindow.autocloud.form.path")}
        value={condition.path}
        data-autocloud-condition-path=""
        onChange={(event) => onChange({ ...condition, path: event.target.value })}
      />
      <select
        aria-label={t("settingsWindow.autocloud.form.op")}
        className={SELECT_CLASS}
        value={condition.op}
        data-autocloud-condition-op=""
        onChange={(event) => onChange({ ...condition, op: event.target.value })}
      >
        {catalog.ops.map((op) => (
          <option key={op.value} value={op.value}>
            {op.label}
          </option>
        ))}
      </select>
      {!VALUELESS_OPS.has(condition.op) && (
        <Input
          className="field"
          spellCheck={false}
          aria-label={t("settingsWindow.autocloud.form.value")}
          placeholder={t("settingsWindow.autocloud.form.value")}
          value={value}
          data-autocloud-condition-value=""
          onChange={(event) => onChange({ ...condition, value: event.target.value })}
        />
      )}
      <Button
        variant="ghost"
        className="button"
        aria-label={t("settingsWindow.autocloud.form.removeCondition")}
        data-autocloud-action="removeCondition"
        onClick={onRemove}
      >
        ×
      </Button>
    </div>
  );
}

function PreviewBlock({ preview }: { preview: AutocloudPreview | null }) {
  if (!preview) return null;
  return (
    <div className="autocloud-preview" data-autocloud-preview={preview.matches ? "match" : "skip"}>
      <div className="row-help" data-autocloud-preview-ref="">
        {`${t("settingsWindow.autocloud.form.ref")}: ${preview.ref}`}
      </div>
      <pre className="autocloud-prompt selectable" data-autocloud-preview-prompt="">
        {preview.prompt}
      </pre>
      {preview.missingText && <div className="row-error">{preview.missingText}</div>}
      {preview.conditions.map((c, i) => (
        <div className="row-help" key={i} data-autocloud-preview-condition={c.holds ? "holds" : "fails"}>
          {`${c.holds ? "✓" : "✗"} ${c.text} · ${c.actualText}`}
        </div>
      ))}
      <div className="row-title">
        <span className="accounts-status devices-status" data-tone={preview.matches ? "success" : "neutral"}>
          <span className="accounts-dot" aria-hidden="true" />
          {preview.matchText}
        </span>
      </div>
    </div>
  );
}

function AutomationForm({
  editing,
  start,
  webhookUrl,
  catalog,
  busy,
  error,
  act,
  onDone,
}: {
  editing: string | null;
  start: AutocloudSpec;
  webhookUrl: string | null;
  catalog: AutocloudCatalog;
  busy: boolean;
  error: AutocloudState["error"];
  act: Act;
  onDone: (answer: AutocloudAnswer) => void;
}) {
  const [spec, setSpec] = useState<AutocloudSpec>(start);
  const [sample, setSample] = useState<string | undefined>(undefined);
  const [preview, setPreview] = useState<AutocloudPreview | null>(null);
  const actRef = useRef(act);
  actRef.current = act;
  // The preview follows the form, a moment after the last keystroke (the CLI renders it, offline).
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => {
      void actRef.current({ action: "preview", spec, sample }).then((answer) => {
        if (live && answer.ok && typeof answer.prompt === "string") setPreview(answer as AutocloudPreview);
      });
    }, 250);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [spec, sample]);
  const trigger = spec.trigger;
  const setAction = (patch: Partial<AutocloudSpec["action"]>) =>
    setSpec({ ...spec, action: { ...spec.action, ...patch } });
  const setGuard = (key: keyof AutocloudSpec["guardrails"], raw: string) => {
    const n = Number.parseInt(raw, 10);
    setSpec({
      ...spec,
      guardrails: {
        ...spec.guardrails,
        [key]: Number.isFinite(n) ? n : undefined,
      },
    });
  };
  const setConditions = (conditions: AutocloudCondition[]) => setSpec({ ...spec, conditions });
  const changeType = (type: string) => {
    if (type === trigger.type) return;
    if (type === "github")
      setSpec({
        ...spec,
        trigger: { type, events: ["ci_failure"], repository: spec.action.repo },
      });
    else if (type === "schedule")
      setSpec({
        ...spec,
        trigger: { type, cron: "0 9 * * 1-5", timeZone: "UTC" },
      });
    else setSpec({ ...spec, trigger: { type } });
  };
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const answer = editing ? await act({ action: "update", id: editing, spec }) : await act({ action: "create", spec });
    if (answer.ok) onDone(answer);
  };
  const known = catalog.triggerTypes.some((choice) => choice.value === trigger.type);
  const github = trigger.type === "github" ? (trigger as Extract<AutocloudSpec["trigger"], { type: "github" }>) : null;
  const schedule =
    trigger.type === "schedule" ? (trigger as Extract<AutocloudSpec["trigger"], { type: "schedule" }>) : null;
  const guard = (key: keyof AutocloudSpec["guardrails"], label: string) => (
    <Field label={label}>
      <Input
        className="field autocloud-number"
        type="number"
        min={0}
        value={spec.guardrails[key] ?? ""}
        data-autocloud-guard={key}
        onChange={(event) => setGuard(key, event.target.value)}
      />
    </Field>
  );
  return (
    <form
      className="group autocloud-form"
      data-autocloud-form={editing ?? "new"}
      onSubmit={(event) => void submit(event)}
    >
      <div className="group-title">
        {editing ? t("settingsWindow.autocloud.form.titleEdit") : t("settingsWindow.autocloud.form.titleNew")}
      </div>
      <Field label={t("settingsWindow.autocloud.form.name")}>
        <Input
          className="field"
          value={spec.name}
          data-autocloud-name=""
          onChange={(event) => setSpec({ ...spec, name: event.target.value })}
        />
      </Field>

      <div className="row-title autocloud-heading">{t("settingsWindow.autocloud.form.trigger")}</div>
      <div className="accounts-buttons hub-form">
        <Field label={t("settingsWindow.autocloud.form.triggerType")}>
          <select
            className={SELECT_CLASS}
            value={trigger.type}
            disabled={!known}
            data-autocloud-trigger-type=""
            onChange={(event) => changeType(event.target.value)}
          >
            {catalog.triggerTypes.map((choice) => (
              <option key={choice.value} value={choice.value}>
                {choice.label}
              </option>
            ))}
            {!known && <option value={trigger.type}>{trigger.type}</option>}
          </select>
        </Field>
        {github && (
          <>
            <Field label={t("settingsWindow.autocloud.form.event")}>
              <select
                className={SELECT_CLASS}
                value={github.events[0] ?? "ci_failure"}
                data-autocloud-event=""
                onChange={(event) => {
                  setSpec({
                    ...spec,
                    trigger: { ...github, events: [event.target.value] },
                  });
                  setSample(event.target.value);
                }}
              >
                {catalog.githubEvents.map((choice) => (
                  <option key={choice.value} value={choice.value}>
                    {choice.label}
                  </option>
                ))}
              </select>
            </Field>
            <Field label={t("settingsWindow.autocloud.form.repository")}>
              <Input
                className="field"
                spellCheck={false}
                placeholder="acme/web"
                value={github.repository}
                data-autocloud-repository=""
                onChange={(event) => {
                  const repository = event.target.value;
                  // The agent works in the repository the event came from until the person names another.
                  const repo = spec.action.repo === github.repository ? repository : spec.action.repo;
                  setSpec({
                    ...spec,
                    trigger: { ...github, repository },
                    action: { ...spec.action, repo },
                  });
                }}
              />
            </Field>
          </>
        )}
        {schedule && (
          <>
            <Field label={t("settingsWindow.autocloud.form.cron")}>
              <Input
                className="field"
                spellCheck={false}
                value={schedule.cron}
                data-autocloud-cron=""
                onChange={(event) =>
                  setSpec({
                    ...spec,
                    trigger: { ...schedule, cron: event.target.value },
                  })
                }
              />
            </Field>
            <Field label={t("settingsWindow.autocloud.form.timeZone")}>
              <Input
                className="field"
                spellCheck={false}
                value={schedule.timeZone ?? "UTC"}
                data-autocloud-timezone=""
                onChange={(event) =>
                  setSpec({
                    ...spec,
                    trigger: { ...schedule, timeZone: event.target.value },
                  })
                }
              />
            </Field>
          </>
        )}
      </div>
      {trigger.type === "webhook" &&
        (webhookUrl ? (
          <div className="row-help selectable" data-autocloud-webhook-url="">
            {`${t("settingsWindow.autocloud.form.webhookUrl")}: ${webhookUrl}`}
          </div>
        ) : (
          <div className="row-help">{t("settingsWindow.autocloud.form.webhookHelp")}</div>
        ))}
      {!known && <div className="row-help">{t("settingsWindow.autocloud.form.otherTrigger")}</div>}

      <div className="row-title autocloud-heading">{t("settingsWindow.autocloud.form.conditions")}</div>
      <div className="row-help">{t("settingsWindow.autocloud.form.conditionsHelp")}</div>
      {spec.conditions.map((condition, index) => (
        <ConditionRow
          key={index}
          condition={condition}
          catalog={catalog}
          onChange={(next) => setConditions(spec.conditions.map((c, i) => (i === index ? next : c)))}
          onRemove={() => setConditions(spec.conditions.filter((_, i) => i !== index))}
        />
      ))}
      <div>
        <Button
          type="button"
          className="button"
          data-autocloud-action="addCondition"
          onClick={() => setConditions([...spec.conditions, { path: "", op: "equals", value: "" }])}
        >
          {t("settingsWindow.autocloud.form.addCondition")}
        </Button>
      </div>

      <div className="row-title autocloud-heading">{t("settingsWindow.autocloud.form.action")}</div>
      <div className="accounts-buttons hub-form">
        <Field label={t("settingsWindow.autocloud.form.repo")}>
          <Input
            className="field"
            spellCheck={false}
            placeholder="acme/web"
            value={spec.action.repo}
            data-autocloud-repo=""
            onChange={(event) => setAction({ repo: event.target.value })}
          />
        </Field>
        <Field label={t("settingsWindow.autocloud.form.ref")}>
          <Input
            className="field"
            spellCheck={false}
            value={spec.action.ref}
            data-autocloud-ref=""
            onChange={(event) => setAction({ ref: event.target.value })}
          />
        </Field>
        <Field label={t("settingsWindow.autocloud.form.harness")}>
          <select
            className={SELECT_CLASS}
            value={spec.action.harness}
            data-autocloud-harness=""
            onChange={(event) => setAction({ harness: event.target.value })}
          >
            {catalog.harnesses.map((choice) => (
              <option key={choice.value} value={choice.value}>
                {choice.label}
              </option>
            ))}
          </select>
        </Field>
      </div>
      <Field label={t("settingsWindow.autocloud.form.prompt")}>
        <textarea
          className="autocloud-textarea"
          rows={6}
          spellCheck={false}
          value={spec.action.prompt}
          aria-label={t("settingsWindow.autocloud.form.prompt")}
          data-autocloud-prompt=""
          onChange={(event) => setAction({ prompt: event.target.value })}
        />
      </Field>
      <div className="row-help">{t("settingsWindow.autocloud.form.promptHelp")}</div>
      <label className="row-help autocloud-check">
        <input
          type="checkbox"
          checked={spec.action.postBack !== "none"}
          aria-label={t("settingsWindow.autocloud.form.postBack")}
          data-autocloud-postback=""
          onChange={(event) => setAction({ postBack: event.target.checked ? "comment" : "none" })}
        />
        {t("settingsWindow.autocloud.form.postBack")}
      </label>
      <label className="row-help autocloud-check">
        <input
          type="checkbox"
          checked={spec.action.openPr === true}
          aria-label={t("settingsWindow.autocloud.form.openPr")}
          data-autocloud-openpr=""
          onChange={(event) => setAction({ openPr: event.target.checked })}
        />
        {t("settingsWindow.autocloud.form.openPr")}
      </label>

      <div className="row-title autocloud-heading">{t("settingsWindow.autocloud.form.preview")}</div>
      <Field label={t("settingsWindow.autocloud.form.sample")}>
        <select
          className={SELECT_CLASS}
          value={preview?.sample ?? sample ?? ""}
          data-autocloud-sample=""
          onChange={(event) => setSample(event.target.value)}
        >
          {catalog.samples.map((choice) => (
            <option key={choice.value} value={choice.value}>
              {choice.label}
            </option>
          ))}
        </select>
      </Field>
      <PreviewBlock preview={preview} />

      <div className="row-title autocloud-heading">{t("settingsWindow.autocloud.form.guardrails")}</div>
      <div className="accounts-buttons hub-form">
        {guard("cooldownSeconds", t("settingsWindow.autocloud.form.cooldown"))}
        {guard("maxRunsPerDay", t("settingsWindow.autocloud.form.maxRunsPerDay"))}
        {guard("maxConcurrent", t("settingsWindow.autocloud.form.maxConcurrent"))}
        {guard("maxMinutesPerRun", t("settingsWindow.autocloud.form.maxMinutes"))}
      </div>

      {error && (error.action === "create" || error.action === "update") && (
        <div className="row-error selectable" role="alert" data-autocloud-error={error.code}>
          {error.message || t("settingsWindow.autocloud.error.notFinished")}
        </div>
      )}
      <div className="accounts-buttons">
        <Button type="submit" variant="solid" className="button" data-autocloud-action="save" disabled={busy}>
          {t("settingsWindow.autocloud.form.save")}
        </Button>
        <Button
          type="button"
          className="button"
          data-autocloud-action="cancelForm"
          onClick={() => onDone({ ok: false })}
        >
          {t("settingsWindow.autocloud.cancel")}
        </Button>
      </div>
    </form>
  );
}

function TemplateRow({ template, onUse }: { template: AutocloudTemplate; onUse: () => void }) {
  const titleId = useId();
  return (
    <div className="row accounts-row" data-autocloud-template={template.id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {template.title}
          </div>
          <div className="row-help">{template.summary}</div>
        </div>
        <span className="row-control">
          <Button className="button" data-autocloud-action="useTemplate" aria-describedby={titleId} onClick={onUse}>
            {t("settingsWindow.autocloud.useTemplate")}
          </Button>
        </span>
      </div>
    </div>
  );
}

type FormOpen = {
  editing: string | null;
  start: AutocloudSpec;
  webhookUrl: string | null;
  key: number;
};
type Created = { url: string | null; secret: string; text?: string };

export function AutomationsCard() {
  const store = useStore();
  const enabled = useRowState("labs.automations").value === true;
  const [state, setState] = useState<AutocloudState | null>(null);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState<FormOpen | null>(null);
  const [runLog, setRunLog] = useState<{
    id: string;
    name: string;
    runs: AutocloudRun[] | null;
  } | null>(null);
  const [created, setCreated] = useState<Created | null>(null);
  const refresh = useCallback(async () => {
    setState((await store.runAutocloud({ action: "refresh" })).state);
  }, [store]);
  useEffect(() => {
    if (!enabled) return;
    void refresh();
  }, [enabled, refresh]);
  const act = useCallback<Act>(
    async (action) => {
      const quiet = action.action === "preview" || action.action === "runs";
      if (!quiet) setBusy(true);
      try {
        const { answer, state: next } = await store.runAutocloud(action);
        if (next) setState(next);
        return answer;
      } finally {
        if (!quiet) setBusy(false);
      }
    },
    [store],
  );
  const overview = state?.overview ?? null;
  const ready = overview?.ok === true && overview.available ? overview : null;
  const open = (editing: string | null, start: AutocloudSpec, webhookUrl: string | null = null) => {
    setRunLog(null);
    setCreated(null);
    setForm({
      editing,
      start: structuredClone(start),
      webhookUrl,
      key: Date.now(),
    });
  };
  const showRuns = async (row: AutocloudAutomation) => {
    setRunLog({ id: row.id, name: row.name, runs: null });
    const answer = await act({ action: "runs", id: row.id });
    setRunLog((log) => (log?.id === row.id ? { ...log, runs: answer.runs ?? [] } : log));
  };
  const listError =
    state?.error && state.error.action !== "create" && state.error.action !== "update" ? state.error : null;
  if (!enabled) return null;
  return (
    <div className="hub-card" data-card="automationsCloud">
      <section className="group" data-autocloud-group="header">
        <div className="group-title">{t("settingsWindow.autocloud.title")}</div>
        <div className="row-help">{t("settingsWindow.autocloud.help")}</div>
        <div className="accounts-header accounts-buttons">
          <Button
            type="button"
            className="button"
            data-autocloud-action="refresh"
            disabled={state?.loading ?? false}
            onClick={() => void refresh()}
          >
            {t("settingsWindow.autocloud.refresh")}
          </Button>
          {ready && !form && (
            <Button
              type="button"
              variant="solid"
              className="button"
              data-autocloud-action="new"
              onClick={() => open(null, blankSpec())}
            >
              {t("settingsWindow.autocloud.new")}
            </Button>
          )}
        </div>
        {!state && (
          <div className="row-help" data-autocloud-checking="">
            {t("settingsWindow.autocloud.checking")}
          </div>
        )}
        {state?.problem === "unavailable" && (
          <div className="row-error" data-autocloud-problem="unavailable">
            {t("settingsWindow.autocloud.problem.unavailable")}
          </div>
        )}
        {overview?.ok === false && (
          <div className="row-error selectable" role="alert" data-autocloud-problem={overview.error.code}>
            {overview.error.message || t("settingsWindow.autocloud.problem.failed")}
          </div>
        )}
        {state?.problem === "failed" && !overview && (
          <div className="row-error" data-autocloud-problem="failed">
            {t("settingsWindow.autocloud.problem.failed")}
          </div>
        )}
        {overview?.ok === true && !overview.available && (
          <div className="row-help" data-autocloud-not-here="">
            {overview.message}
          </div>
        )}
        {listError && (
          <div className="row-error hub-note selectable" role="alert" data-autocloud-error={listError.code}>
            {listError.message || t("settingsWindow.autocloud.error.notFinished")}
          </div>
        )}
      </section>

      {created && (
        <SecretOnce url={created.url} secret={created.secret} text={created.text} onDone={() => setCreated(null)} />
      )}

      {ready && form && (
        <AutomationForm
          key={form.key}
          editing={form.editing}
          start={form.start}
          webhookUrl={form.webhookUrl}
          catalog={ready.catalog}
          busy={busy}
          error={state?.error ?? null}
          act={act}
          onDone={(answer) => {
            setForm(null);
            if (answer.secret)
              setCreated({
                url: answer.automation?.webhookUrl ?? null,
                secret: answer.secret,
                text: answer.secretText,
              });
          }}
        />
      )}

      {ready && !form && runLog && <RunLog name={runLog.name} runs={runLog.runs} onClose={() => setRunLog(null)} />}

      {ready && !form && (
        <section className="group" data-autocloud-group="list">
          <div className="group-title">{t("settingsWindow.autocloud.list")}</div>
          {ready.automations.length === 0 ? (
            <div className="row-help" data-autocloud-empty="list">
              {t("settingsWindow.autocloud.empty")}
            </div>
          ) : (
            <div className="rows">
              {ready.automations.map((row) => (
                <AutomationRow
                  key={row.id}
                  row={row}
                  busy={busy}
                  act={act}
                  onEdit={() => open(row.id, row.spec, row.webhookUrl)}
                  onRuns={() => void showRuns(row)}
                />
              ))}
            </div>
          )}
        </section>
      )}

      {ready && !form && ready.templates.length > 0 && (
        <section className="group" data-autocloud-group="templates">
          <div className="group-title">{t("settingsWindow.autocloud.templates")}</div>
          <div className="rows">
            {ready.templates.map((template) => (
              <TemplateRow key={template.id} template={template} onUse={() => open(null, template.spec)} />
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
