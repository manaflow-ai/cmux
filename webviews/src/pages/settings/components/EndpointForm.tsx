// Settings > Agents > Add > Endpoint (plan api-and-open-models gaps 3 and 6): an open-weight model
// or your own endpoint as a harness, as easy as picking Claude or Codex. A preset fills the URL and
// says whether a key is needed; Fetch Models asks the endpoint for its list; Check and Add stores
// the key in the Keychain, writes the profile and sends one real prompt, and the panel closes only
// once that answered (the new harness is then in the model picker). The fields and the add-then-check
// sequence are the Chief editor's (shared/byoEndpoint.ts, shared/EndpointFields.tsx), through the
// same host calls (`cmux.chief.backend.add|doctor|list`, the app's AgentHarnessCenter).
import { useEffect, useMemo, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { StableLabel } from "../../../ui/StableLabel";
import { ChiefHost } from "../../home-channels/chiefEditing";
import { EndpointFields } from "../../shared/EndpointFields";
import {
  ENDPOINT_PRESETS,
  addedTarget,
  bringEndpoint,
  canFetchModels,
  endpointBackend,
  endpointBusy,
  endpointPreset,
  endpointProblemAt,
  failureText,
  fetchEndpointModels,
  newTarget,
  type AddTarget,
  type EndpointDraft,
  type EndpointPresetId,
  type EndpointService,
  type EndpointStatus,
} from "../../shared/byoEndpoint";
import { useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

const field = "field w-full";
const label = "mb-0.5 block text-[12px] text-muted";

/** A preset's picker label. Product names stay out: only Claude and Codex are named. */
const presetLabel = (id: EndpointPresetId) =>
  ({
    "local-server": t("settingsPage.agents.endpoint.preset.localServer"),
    "desktop-app": t("settingsPage.agents.endpoint.preset.desktopApp"),
    "team-server": t("settingsPage.agents.endpoint.preset.teamServer"),
    hosted: t("settingsPage.agents.endpoint.preset.hosted"),
    gateway: t("settingsPage.agents.endpoint.preset.gateway"),
  })[id];

/** The name a preset's harness starts with (the model picker shows it). */
const presetName = (id: EndpointPresetId) =>
  ({
    "local-server": t("settingsPage.agents.endpoint.name.localServer"),
    "desktop-app": t("settingsPage.agents.endpoint.name.desktopApp"),
    "team-server": t("settingsPage.agents.endpoint.name.teamServer"),
    hosted: t("settingsPage.agents.endpoint.name.hosted"),
    gateway: t("settingsPage.agents.endpoint.name.gateway"),
  })[id];

const presetHint = (id: EndpointPresetId) =>
  ({
    "local-server": t("settingsPage.agents.endpoint.hint.local"),
    "desktop-app": t("settingsPage.agents.endpoint.hint.local"),
    "team-server": t("settingsPage.agents.endpoint.hint.team"),
    hosted: t("settingsPage.agents.endpoint.hint.hosted"),
    gateway: t("settingsPage.agents.endpoint.hint.gateway"),
  })[id];

/** The draft a preset starts: its URL and default name, no models or key yet. */
export function presetDraft(id: EndpointPresetId): EndpointDraft {
  const preset = endpointPreset(id);
  return {
    kind: preset.kind,
    name: presetName(id),
    baseUrl: preset.baseUrl,
    models: "",
    apiKey: "",
  };
}

export function EndpointForm({ done }: { done: () => void }) {
  const store = useStore();
  const service: EndpointService = useMemo(() => new ChiefHost(store.chiefCalls), [store]);
  const [presetId, setPresetId] = useState<EndpointPresetId>("local-server");
  const [draft, setDraft] = useState<EndpointDraft>(() => presetDraft("local-server"));
  const [status, setStatus] = useState<EndpointStatus>({ state: "editing" });
  const [fetched, setFetched] = useState<{ count: number } | { error: string } | null>(null);
  // The harness this form added (Fetch Models, or a Check and Add whose check failed): every later
  // add writes it again, never another one; closed without a passing check, it is removed. Owned
  // the moment an add answers (before its check), and an add that answers after the form closed
  // (Cancel stays live during the add and the check) is removed then.
  const [target, setTarget] = useState<AddTarget | null>(null);
  const own = useRef<{ id: string | null; saved: boolean; closed: boolean }>({ id: null, saved: false, closed: false });
  useEffect(() => {
    const mine = own.current;
    mine.closed = false;
    return () => {
      mine.closed = true;
      if (mine.id && !mine.saved) void store.runAgents({ action: "remove", id: mine.id });
    };
  }, [store]);
  const claim = (id: string) => {
    own.current.id = id;
    if (own.current.closed) void store.runAgents({ action: "remove", id });
  };
  const preset = endpointPreset(presetId);
  const busy = endpointBusy(status);
  const problem = endpointProblemAt(draft, preset.key, target);
  const targetFor = async () => target ?? (await newTarget(service, draft, preset.idBase));
  const owned = (next: AddTarget) => {
    own.current.id = next.id;
    setTarget(next);
  };
  const change = (patch: Partial<EndpointDraft>) => setDraft((before) => ({ ...before, ...patch }));
  const pick = (id: EndpointPresetId) => {
    // The typed name and models stay unless they were the last preset's; the key never carries over.
    setDraft((before) => {
      const next = presetDraft(id);
      const ownName = before.name.trim() !== "" && before.name !== presetDraft(presetId).name;
      return { ...next, name: ownName ? before.name : next.name, models: before.models };
    });
    setPresetId(id);
    setFetched(null);
    setStatus({ state: "editing" });
  };
  const fetchModels = async () => {
    if (busy || !canFetchModels(draft, preset.key, target)) return;
    setStatus({ state: "fetching" });
    setFetched(null);
    try {
      const answer = await fetchEndpointModels(service, draft, await targetFor(), claim);
      owned(answer.target);
      // The key is stored now: the field empties, and a save keeps what was stored.
      change({ apiKey: "" });
      const models = answer.models;
      if (models.length > 0) change({ models: models.join(", ") });
      setFetched({ count: models.length });
    } catch (failure) {
      setFetched({ error: failureText(failure) });
    }
    setStatus({ state: "editing" });
  };
  const submit = async () => {
    if (busy || problem) return;
    setStatus({ state: "adding" });
    let at: AddTarget;
    try {
      at = await targetFor();
    } catch (failure) {
      return setStatus({ state: "failed", step: { name: "add", ok: false, detail: failureText(failure) } });
    }
    const backend = endpointBackend(draft, at);
    // The key leaves the page's state now: only the host's add call carries it.
    change({ apiKey: "" });
    const result = await bringEndpoint(service, backend, setStatus, claim);
    if (result.state !== "failed" || result.harness) owned(addedTarget(at, backend));
    if (result.state === "passed" && !own.current.closed) {
      own.current.saved = true;
      done();
    }
  };
  return (
    <form
      className="grid grid-cols-2 gap-x-3 gap-y-2"
      data-agents-endpoint={presetId}
      aria-busy={busy || undefined}
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <label className="col-span-1">
        <span className={label}>{t("settingsPage.agents.endpoint.preset")}</span>
        <select
          aria-label={t("settingsPage.agents.endpoint.preset")}
          className="box-border h-7 w-full rounded-md border border-solid border-edge bg-transparent px-2 font-[inherit] text-control text-fg outline-none focus:border-accent-soft"
          value={presetId}
          disabled={busy}
          onChange={(event) => pick(event.target.value as EndpointPresetId)}
        >
          {ENDPOINT_PRESETS.map((entry) => (
            <option key={entry.id} value={entry.id}>
              {presetLabel(entry.id)}
            </option>
          ))}
        </select>
      </label>
      <label className="col-span-1">
        <span className={label}>{t("settingsPage.agents.name")}</span>
        <Input
          variant="outline"
          aria-label={t("settingsPage.agents.name")}
          className={field}
          value={draft.name}
          maxLength={64}
          disabled={busy}
          onChange={(event) => change({ name: event.target.value })}
        />
      </label>
      <p className="col-span-2 m-0 text-[12px] text-muted" data-endpoint-hint>
        {presetHint(presetId)}
      </p>
      <EndpointFields
        draft={draft}
        change={change}
        labels={{
          baseUrl: t("settingsPage.agents.endpoint.baseUrl"),
          models: t("settingsPage.agents.endpoint.models"),
          apiKey: t(
            preset.key === "required"
              ? "settingsPage.agents.endpoint.apiKey"
              : "settingsPage.agents.endpoint.apiKeyOptional",
          ),
        }}
        placeholders={{ baseUrl: preset.example }}
        field={(spec) => {
          // A model server on this Mac takes no key: no field for one.
          if (spec.name === "apiKey" && preset.key === "none") return null;
          return (
            <div className="col-span-2" data-endpoint-field={spec.name}>
              <label>
                <span className={label}>{spec.label}</span>
                <span className="flex items-center gap-2">
                  <Input
                    variant="outline"
                    aria-label={spec.label}
                    className={`${field} flex-1 ${spec.name === "apiKey" ? "" : "font-mono"}`}
                    value={spec.value}
                    disabled={busy}
                    onChange={(event) => spec.set(event.target.value)}
                    type={spec.attrs.type}
                    placeholder={spec.attrs.placeholder}
                    spellCheck={spec.attrs.spellCheck}
                    autoComplete={spec.attrs.autoComplete}
                    maxLength={spec.attrs.maxLength}
                  />
                  {spec.name === "models" && (
                    <Button
                      type="button"
                      className="button"
                      disabled={busy || !canFetchModels(draft, preset.key, target)}
                      onClick={() => void fetchModels()}
                    >
                      {t("settingsPage.agents.endpoint.fetch")}
                    </Button>
                  )}
                </span>
              </label>
              {spec.name === "baseUrl" && problem === "insecure" && (
                <span className="mt-0.5 block text-[11px] text-warning">
                  {t("settingsPage.agents.endpoint.insecure")}
                </span>
              )}
              {spec.name === "models" && <ModelsNote fetched={fetched} />}
              {spec.name === "apiKey" && (
                <span className="mt-0.5 block text-[11px] text-soft" data-endpoint-key-note>
                  {target?.own && target.typedKey && !draft.apiKey
                    ? t("settingsPage.agents.endpoint.keyStored")
                    : t("settingsPage.agents.endpoint.keyNote")}
                </span>
              )}
            </div>
          );
        }}
      />
      <EndpointProgress status={status} />
      <div className="col-span-2 flex justify-end">
        <Button type="submit" className="button" disabled={busy || problem !== null} data-endpoint-add="">
          <StableLabel
            label={busy ? t("settingsPage.agents.checking") : t("settingsPage.agents.endpoint.add")}
            alternatives={[t("settingsPage.agents.endpoint.add"), t("settingsPage.agents.checking")]}
          />
        </Button>
      </div>
    </form>
  );
}

function ModelsNote({ fetched }: { fetched: { count: number } | { error: string } | null }) {
  if (fetched && "error" in fetched)
    return (
      <span className="mt-0.5 block text-[11px] text-danger" role="alert" data-endpoint-fetched="failed">
        {fetched.error}
      </span>
    );
  if (fetched)
    return (
      <span className="mt-0.5 block text-[11px] text-soft" data-endpoint-fetched={fetched.count}>
        {t("settingsPage.agents.endpoint.fetched", fetched.count)}
      </span>
    );
  return <span className="mt-0.5 block text-[11px] text-soft">{t("settingsPage.agents.endpoint.modelsHelp")}</span>;
}

function EndpointProgress({ status }: { status: EndpointStatus }) {
  if (status.state === "fetching" || status.state === "adding" || status.state === "checking") {
    const key =
      status.state === "fetching"
        ? "settingsPage.agents.endpoint.fetching"
        : status.state === "adding"
          ? "settingsPage.agents.endpoint.adding"
          : "settingsPage.agents.endpoint.checking";
    return (
      <output
        className="col-span-2 block text-[12px] text-muted"
        aria-live="polite"
        data-endpoint-status={status.state}
      >
        {t(key)}
      </output>
    );
  }
  if (status.state !== "failed") return null;
  const step = status.step;
  return (
    <div className="col-span-2 flex gap-1.5 text-[12px]" role="alert" data-endpoint-status="failed">
      <span aria-hidden="true" className="inline-flex w-4 flex-none justify-center text-danger">
        <Icon name="xmark" />
      </span>
      <span className="min-w-0">
        <span className="text-danger">{t("settingsPage.agents.endpoint.failed", step?.name || "doctor")}</span>
        {step?.detail && <span className="text-muted"> · {step.detail}</span>}
        {step?.fix && <span className="block text-muted">{t("settingsPage.agents.fix", step.fix)}</span>}
      </span>
    </div>
  );
}
