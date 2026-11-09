// The Chief editor's Backend (ChiefPage.tsx): the acpmux harness the Chief thinks with, its model
// and effort ("Default (Chief's usual)": the owner's default), or one the person brings: an ACP
// agent command, or an Anthropic- or OpenAI-compatible endpoint with its key. The key goes to the
// host in the one add call (the Keychain from there) and leaves the page's state as the form is
// sent. The host then runs a real hello turn (doctor, prompt) and the page shows Checking…, then
// that it answered, or the step that failed and its fix; the editor saves a new harness only
// after its check passed.
import { useEffect, useId, useState, type InputHTMLAttributes } from "react";
import type { Strings } from "../shared/i18n";
import { EndpointFields } from "../shared/EndpointFields";
import {
  bringEndpoint,
  checkEndpoint,
  endpointBackend,
  endpointBusy,
  modelList,
  ownedAfter,
  type AddTarget,
  type EndpointDraft,
  type EndpointKind,
  type EndpointStatus,
} from "../shared/byoEndpoint";
import { useNextTarget, useOwnedEndpoint } from "../shared/useOwnedEndpoint";
import type { ChiefEditorService } from "./chiefEditing";
import { chiefEffortName, chiefModelName } from "./chiefNames";
import {
  chiefBackend,
  type HomeChiefBackend,
  type HomeChiefByoBackend,
  type HomeChiefDoctor,
  type HomeChiefEngine,
} from "./types";

/** The check of the harness the person picked. */
export type BackendCheck =
  | { state: "idle" }
  | { state: "checking"; harness: string }
  | { state: "passed"; harness: string }
  | { state: "failed"; harness: string; step?: HomeChiefDoctor["steps"][number] };

// Not a harness id (those are lowercase words and dashes).
const BYO = "__bring-your-own__";

export function ChiefBackendPicker({
  service,
  strings,
  engine,
  disabled,
  check,
  onChange,
  onRecheck,
  onBrought,
}: {
  service: ChiefEditorService;
  strings: Strings;
  engine: HomeChiefEngine;
  disabled: boolean;
  check: BackendCheck;
  onChange(engine: HomeChiefEngine): void;
  onRecheck(): void;
  /** A brought backend passed its check: the editor picks it. */
  onBrought(harness: string, model: string): void;
}) {
  const { t, format } = strings;
  const [backends, setBackends] = useState<HomeChiefBackend[] | undefined>();
  const [failed, setFailed] = useState(false);
  const [bringing, setBringing] = useState(false);
  const [stamp, setStamp] = useState(0);
  useEffect(() => {
    let live = true;
    service.backends().then(
      (list) => {
        if (!live) return;
        setBackends(list);
        setFailed(false);
      },
      () => {
        if (!live) return;
        setBackends([]);
        setFailed(true);
      },
    );
    return () => {
      live = false;
    };
  }, [service, stamp]);
  const list = backends ?? [];
  const current = list.find((backend) => backend.id === engine.harness);
  // The record's harness stays a choice while acpmux does not list it (removed, or not loaded).
  const options =
    engine.harness && !current ? [...list, { id: engine.harness, name: engine.harness, models: [] }] : list;
  const models = current?.models ?? [];
  const model = models.find((entry) => entry.id === engine.model);
  // Effort options from the harness's capabilities when acpmux reports them: the picked model's,
  // else every effort its models take.
  const efforts = model ? model.efforts : [...new Set(models.flatMap((entry) => entry.efforts))];
  const ids = { backend: useId(), model: useId(), effort: useId() };
  return (
    <div className="ce-field ce-backend" data-chief-backend="">
      <label className="ce-label" htmlFor={ids.backend}>
        {t("chief.backend.title")}
      </label>
      <span className="ce-row ce-backend-row">
        <select
          id={ids.backend}
          className="ce-input ce-select"
          aria-label={t("chief.backend.title")}
          disabled={disabled}
          value={engine.harness}
          onChange={(event) => {
            if (event.target.value === BYO) return setBringing(true);
            onChange({ harness: event.target.value, model: "", effort: "" });
          }}
        >
          <option value="">{t("chief.backend.default")}</option>
          {options.map((backend) => (
            <option key={backend.id} value={backend.id}>
              {"unavailable" in backend && backend.unavailable
                ? format("chief.backend.unavailable", backend.name)
                : backend.name}
            </option>
          ))}
          <option value={BYO}>{t("chief.backend.byo")}</option>
        </select>
        <label className="ce-sublabel" htmlFor={ids.model}>
          {t("chief.backend.model")}
        </label>
        {models.length > 0 ? (
          <select
            id={ids.model}
            className="ce-input ce-select"
            aria-label={t("chief.backend.model")}
            disabled={disabled || !engine.harness}
            value={engine.model}
            onChange={(event) => onChange({ ...engine, model: event.target.value, effort: "" })}
          >
            <option value="">{t("chief.backend.usual")}</option>
            {models.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {entry.name}
              </option>
            ))}
            {engine.model && !model && (
              <option value={engine.model}>{chiefModelName(engine.model, models, strings)}</option>
            )}
          </select>
        ) : (
          <input
            id={ids.model}
            className="ce-input"
            aria-label={t("chief.backend.model")}
            disabled={disabled || !engine.harness}
            value={engine.model}
            placeholder={t("chief.backend.usual")}
            maxLength={128}
            onChange={(event) => onChange({ ...engine, model: event.target.value.trim() })}
          />
        )}
        <label className="ce-sublabel" htmlFor={ids.effort}>
          {t("chief.backend.effort")}
        </label>
        <select
          id={ids.effort}
          className="ce-input ce-select"
          aria-label={t("chief.backend.effort")}
          disabled={disabled || !engine.harness || (efforts.length === 0 && !engine.effort)}
          value={engine.effort}
          onChange={(event) => onChange({ ...engine, effort: event.target.value })}
        >
          <option value="">{t("chief.backend.usual")}</option>
          {efforts.map((effort) => (
            <option key={effort} value={effort}>
              {chiefEffortName(effort, strings)}
            </option>
          ))}
          {engine.effort && !efforts.includes(engine.effort) && (
            <option value={engine.effort}>{chiefEffortName(engine.effort, strings)}</option>
          )}
        </select>
      </span>
      <span className="ce-note">
        {backends === undefined
          ? t("chief.backend.loading")
          : failed
            ? t("chief.backend.none")
            : t("chief.backend.note")}
      </span>
      {engine.harness !== "" && chiefBackend(engine.harness) === "unii" && (
        <span className="ce-note">
          {/* The command stays as typed in every language: the catalog holds its place, %@. */}
          {t("chief.backend.uniiNote")
            .split("%@")
            .flatMap((part, index) => (index === 0 ? [part] : [<code key={index}>unii login</code>, part]))}
        </span>
      )}
      <CheckLine strings={strings} check={check} onRecheck={onRecheck} />
      {bringing && (
        <BringYourOwn
          service={service}
          strings={strings}
          onCancel={() => setBringing(false)}
          onPassed={(harness, model) => {
            setBringing(false);
            setStamp((n) => n + 1);
            onBrought(harness, model);
          }}
        />
      )}
    </div>
  );
}

function CheckLine({ strings, check, onRecheck }: { strings: Strings; check: BackendCheck; onRecheck(): void }) {
  const { t } = strings;
  if (check.state === "idle") return null;
  if (check.state === "checking")
    return (
      <output className="ce-check checking" aria-live="polite">
        {t("chief.backend.checking")}
      </output>
    );
  if (check.state === "passed")
    return (
      <output className="ce-check passed" aria-live="polite">
        {t("chief.backend.passed")}
      </output>
    );
  return <Failure strings={strings} step={check.step} onRetry={onRecheck} />;
}

function Failure({
  strings,
  step,
  onRetry,
}: {
  strings: Strings;
  step?: HomeChiefDoctor["steps"][number];
  onRetry?(): void;
}) {
  const { t, format } = strings;
  return (
    <output className="ce-check failed selectable" role="alert">
      <span>{format("chief.backend.failed", step?.name || "doctor")}</span>
      {step?.detail && <span className="ce-check-detail">{step.detail}</span>}
      {step?.fix && <span className="ce-check-fix">{format("chief.backend.fix", step.fix)}</span>}
      {onRetry && (
        <button type="button" className="ce-button" onClick={onRetry}>
          {t("chief.backend.recheck")}
        </button>
      )}
    </output>
  );
}

type Kind = HomeChiefByoBackend["kind"];

/** The inline Bring your own form: three kinds, then add (the host) and check (a hello turn). The
 * endpoint fields and the add-then-check sequence are the ones Settings > Agents > Add > Endpoint
 * uses (shared/byoEndpoint.ts). */
function BringYourOwn({
  service,
  strings,
  onCancel,
  onPassed,
}: {
  service: ChiefEditorService;
  strings: Strings;
  onCancel(): void;
  onPassed(harness: string, model: string): void;
}) {
  const { t } = strings;
  const [kind, setKind] = useState<Kind>("anthropic-endpoint");
  const [name, setName] = useState("");
  const [command, setCommand] = useState("");
  const [args, setArgs] = useState("");
  // The key lives in the draft only while the person types it; sending the form clears it.
  const [draft, setDraft] = useState<Omit<EndpointDraft, "kind" | "name">>({ baseUrl: "", models: "", apiKey: "" });
  const [status, setStatus] = useState<EndpointStatus>({ state: "editing" });
  // The model a passed check picks: the first of the endpoint's.
  const [picked, setPicked] = useState("");
  // The endpoint harness this form added: an Add after a failed check writes it again (`target`).
  // Closed without a passing check, it is removed (`owned`, the Settings Endpoint form's rule); a
  // change of kind or URL starts over.
  const [target, setTarget] = useState<AddTarget | null>(null);
  const owned = useOwnedEndpoint((id) => service.removeBackend?.(id));
  const startOver = () => {
    owned.discard();
    setTarget(null);
    setStatus({ state: "editing" });
  };
  const endpoint = kind !== "command";
  // The next add's id, picked ahead of the click (no read between the click and the add).
  const targetFor = useNextTarget(service, name, kind, target);
  const busy = endpointBusy(status);
  const complete =
    name.trim() !== "" &&
    (endpoint
      ? draft.baseUrl.trim() !== "" &&
        modelList(draft.models).length > 0 &&
        (draft.apiKey !== "" || !!(target?.own && target.typedKey))
      : command.trim() !== "");
  const recheck = async (harness: string) => {
    setStatus({ state: "checking", harness });
    const checked = await checkEndpoint(service, harness);
    if (checked.state === "passed") {
      owned.keep();
      return onPassed(harness, picked);
    }
    setStatus(checked);
  };
  const submit = async () => {
    if (!complete || busy) return;
    const model = endpoint ? (modelList(draft.models)[0] ?? "") : "";
    const full = { ...draft, kind: kind as EndpointKind, name };
    const at = endpoint ? targetFor() : undefined;
    const backend: HomeChiefByoBackend = endpoint
      ? endpointBackend(full, at)
      : { kind: "command", name: name.trim(), command: command.trim(), args: words(args) };
    // The form owns what an add wrote as soon as it answers (or what a failed add may have written).
    const added =
      at && backend.kind !== "command"
        ? (harness: string, answered: boolean) => {
            owned.claim(harness);
            setTarget(ownedAfter(at, backend, harness, answered));
          }
        : undefined;
    // The key leaves the page's state now: only the host's add call carries it.
    setDraft((before) => ({ ...before, apiKey: "" }));
    setPicked(model);
    const done = await bringEndpoint(service, backend, setStatus, added);
    if (done.state === "passed" && !owned.closed) {
      owned.keep();
      onPassed(done.harness, model);
    }
  };
  const kinds: [Kind, string][] = [
    ["command", t("chief.byo.kind.command")],
    ["anthropic-endpoint", t("chief.byo.kind.anthropic")],
    ["openai-endpoint", t("chief.byo.kind.openai")],
  ];
  const text = (
    label: string,
    value: string,
    set: (value: string) => void,
    extra: InputHTMLAttributes<HTMLInputElement> = {},
  ) => (
    <label className="ce-field">
      <span className="ce-label">{label}</span>
      <input
        className="ce-input"
        aria-label={label}
        value={value}
        disabled={busy}
        onChange={(event) => set(event.target.value)}
        {...extra}
      />
    </label>
  );
  // A nested form is not valid HTML: the group is a fieldset whose button submits it by hand.
  return (
    <fieldset
      className="ce-byo"
      data-chief-byo=""
      aria-busy={busy || undefined}
      // Return in a field adds this backend (ChiefPage's submit clicks the Add button).
    >
      <legend className="ce-label">{t("chief.byo.title")}</legend>
      <fieldset className="ce-byo-kinds" aria-label={t("chief.byo.kind")}>
        {kinds.map(([value, label]) => (
          <label key={value} className="ce-grant-item">
            <input
              type="radio"
              name="chief-byo-kind"
              value={value}
              aria-label={label}
              checked={kind === value}
              disabled={busy}
              onChange={() => {
                if (value !== kind) startOver();
                setKind(value);
              }}
            />
            <span>{label}</span>
          </label>
        ))}
      </fieldset>
      {text(t("chief.byo.name"), name, setName, { placeholder: t("chief.byo.namePlaceholder"), maxLength: 64 })}
      {endpoint ? (
        <>
          <EndpointFields
            draft={{ ...draft, kind: kind as EndpointKind, name }}
            change={(patch) => {
              if (patch.baseUrl !== undefined && patch.baseUrl !== draft.baseUrl) startOver();
              setDraft((before) => ({ ...before, ...patch }));
            }}
            labels={{ baseUrl: t("chief.byo.baseUrl"), models: t("chief.byo.model"), apiKey: t("chief.byo.apiKey") }}
            placeholders={{
              baseUrl: kind === "anthropic-endpoint" ? "https://api.anthropic.com" : "https://api.openai.com/v1",
            }}
            field={(spec) => text(spec.label, spec.value, spec.set, spec.attrs)}
          />
          <span className="ce-note">{t("chief.byo.keyNote")}</span>
        </>
      ) : (
        <>
          {text(t("chief.byo.command"), command, setCommand, { spellCheck: false, placeholder: "my-agent" })}
          {text(t("chief.byo.args"), args, setArgs, { spellCheck: false, placeholder: "--acp" })}
        </>
      )}
      {status.state === "adding" && <output className="ce-check checking">{t("chief.byo.adding")}</output>}
      {status.state === "checking" && (
        <output className="ce-check checking" aria-live="polite">
          {t("chief.backend.checking")}
        </output>
      )}
      {status.state === "failed" && (
        <Failure
          strings={strings}
          step={status.step}
          onRetry={status.harness ? () => void recheck(status.harness!) : undefined}
        />
      )}
      <span className="ce-row ce-byo-actions">
        <button type="button" className="ce-button" disabled={busy} onClick={onCancel}>
          {t("edit.cancel")}
        </button>
        <button
          type="button"
          className="ce-button primary"
          data-chief-byo-add=""
          disabled={!complete || busy}
          onClick={() => void submit()}
        >
          {t("chief.byo.add")}
        </button>
      </span>
    </fieldset>
  );
}

/** Splits an argument line into words: plain words and quoted strings. */
export function words(line: string): string[] {
  const out: string[] = [];
  const pattern = /"([^"]*)"|'([^']*)'|(\S+)/g;
  for (let match = pattern.exec(line); match; match = pattern.exec(line)) out.push(match[1] ?? match[2] ?? match[3]!);
  return out;
}
