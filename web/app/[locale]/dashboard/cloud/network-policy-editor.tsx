"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import { useState } from "react";
import {
  NetworkPolicyValidationError,
  parseNetworkPolicy,
  type NetworkPolicy,
  type NetworkPolicyMode,
  type NetworkPolicyPreset,
  type NetworkPolicyRange,
  type NetworkRangeProtocol,
} from "@/services/vms/networkPolicy";
import { Modal } from "../../components/modal";

/** GET/PUT /api/vm/{id}/network response (`defaultPolicy` is unused here). */
type NetworkState = {
  readonly policy: NetworkPolicy;
  readonly presets: readonly NetworkPolicyPreset[];
  readonly requiredDomains: readonly string[];
  readonly applied: {
    readonly state: "applied" | "pending" | "failed";
    readonly error?: string;
    readonly appliedAt?: string | number;
  };
};

/** A validation failure anchored to a policy path such as `domains.3` or `ranges.1.cidr`. */
type FieldError = { readonly path: string; readonly message: string };

/**
 * 501 `vm_operation_unsupported` from the API: this machine's provider has no
 * outbound network control. Kept as a sentinel path so the UI shows its own copy.
 */
const UNSUPPORTED_ERROR = "vm_operation_unsupported";

const MODES: readonly NetworkPolicyMode[] = ["full", "allowlist", "none"];

function networkUrl(vmId: string, teamId: string | null): string {
  const base = `/api/vm/${encodeURIComponent(vmId)}/network`;
  return teamId ? `${base}?teamId=${encodeURIComponent(teamId)}` : base;
}

async function readNetworkState(response: Response): Promise<NetworkState | FieldError> {
  const body: unknown = await response.json().catch(() => null);
  if (response.ok && body && typeof body === "object" && "policy" in body) return body as NetworkState;
  const error = (body ?? {}) as { path?: unknown; message?: unknown; error?: unknown };
  if (response.status === 501 || error.error === UNSUPPORTED_ERROR) return { path: UNSUPPORTED_ERROR, message: "" };
  const message = typeof error.message === "string" ? error.message
    : typeof error.error === "string" ? error.error : "";
  return { path: typeof error.path === "string" ? error.path : "", message };
}

/**
 * Validate a prospective policy with the same parser the API runs, so an
 * entry is normalized (lowercased, canonical CIDR) or rejected as it is added.
 * The server stays authoritative on save.
 */
function tryPolicy(candidate: NetworkPolicy): { policy: NetworkPolicy } | { error: FieldError } {
  try {
    return { policy: parseNetworkPolicy(candidate) };
  } catch (error) {
    if (error instanceof NetworkPolicyValidationError) return { error: { path: error.path, message: error.message } };
    throw error;
  }
}

function samePolicy(a: NetworkPolicy, b: NetworkPolicy): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function MachineNetworkControl({
  vmId,
  teamId,
  name,
}: {
  readonly vmId: string;
  readonly teamId: string | null;
  readonly name: string;
}) {
  const t = useTranslations("dashboard.cloud.network");
  const errorText = (error: FieldError, fallback: string) =>
    error.path === UNSUPPORTED_ERROR ? t("unsupported") : error.message || fallback;
  const [open, setOpen] = useState(false);
  const [state, setState] = useState<NetworkState | null>(null);
  const [draft, setDraft] = useState<NetworkPolicy | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<FieldError | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setBusy(true);
    setLoadError(null);
    try {
      const result = await readNetworkState(await fetch(networkUrl(vmId, teamId), { cache: "no-store" }));
      if ("policy" in result) {
        setState(result);
        setDraft(null);
        setSaveError(null);
      } else {
        setLoadError(errorText(result, t("loadError")));
      }
    } catch {
      setLoadError(t("loadError"));
    } finally {
      setBusy(false);
    }
  }

  function openEditor() {
    setOpen(true);
    void load();
  }

  const policy = draft ?? state?.policy ?? null;
  const dirty = !!state && !!draft && !samePolicy(draft, state.policy);

  async function save() {
    if (!policy) return;
    setBusy(true);
    setSaveError(null);
    try {
      const result = await readNetworkState(await fetch(networkUrl(vmId, teamId), {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(policy),
      }));
      if ("policy" in result) {
        setState(result);
        setDraft(null);
      } else {
        const path = result.path === UNSUPPORTED_ERROR ? "" : result.path;
        setSaveError({ path, message: errorText(result, t("saveError")) });
      }
    } catch {
      setSaveError({ path: "", message: t("saveError") });
    } finally {
      setBusy(false);
    }
  }

  function update(next: NetworkPolicy) {
    setDraft(next);
    setSaveError(null);
  }

  return (
    <>
      <button className="border border-border px-2 py-1 hover:bg-code-bg" onClick={openEditor}>
        {t("open")}
      </button>
      <Modal open={open} onOpenChange={setOpen} className="max-w-2xl">
        <Dialog.Title className="text-sm font-medium">{t("title", { name })}</Dialog.Title>
        <Dialog.Description className="mt-1 text-xs text-muted">{t("description")}</Dialog.Description>
        {loadError ? (
          <div className="mt-4 space-y-2 text-xs">
            <p role="alert">{loadError}</p>
            <button className="border border-border px-2 py-1 hover:bg-code-bg" onClick={() => void load()} disabled={busy}>
              {t("retry")}
            </button>
          </div>
        ) : null}
        {!state && !loadError ? <p className="mt-4 text-xs text-muted">{t("loading")}</p> : null}
        {state && policy ? (
          <div className="mt-4 space-y-5 text-xs">
            <AppliedStatus applied={state.applied} dirty={dirty} busy={busy} onRefresh={() => void load()} />
            <ModePicker mode={policy.mode} onChange={(mode) => update({ ...policy, mode })} />
            {policy.mode === "allowlist" ? (
              <AllowlistEditor policy={policy} presets={state.presets} saveError={saveError} onChange={update} />
            ) : null}
            <RequiredHosts domains={state.requiredDomains} />
            {saveError && !saveError.path.match(/^(domains|ranges)\.\d+/) ? (
              <p role="alert" className="text-foreground">{saveError.path ? `${saveError.path}: ` : ""}{saveError.message}</p>
            ) : null}
            <div className="flex justify-end gap-2 border-t border-border pt-4">
              {dirty ? (
                <button className="border border-border px-3 py-1.5" onClick={() => { setDraft(null); setSaveError(null); }} disabled={busy}>
                  {t("discard")}
                </button>
              ) : null}
              <Dialog.Close className="border border-border px-3 py-1.5">{t("close")}</Dialog.Close>
              <button
                onClick={() => void save()}
                disabled={busy || !dirty}
                className="border border-foreground bg-foreground px-3 py-1.5 text-background disabled:opacity-50"
              >
                {t("apply")}
              </button>
            </div>
          </div>
        ) : null}
      </Modal>
    </>
  );
}

function AppliedStatus({
  applied,
  dirty,
  busy,
  onRefresh,
}: {
  readonly applied: NetworkState["applied"];
  readonly dirty: boolean;
  readonly busy: boolean;
  readonly onRefresh: () => void;
}) {
  const t = useTranslations("dashboard.cloud.network");
  const appliedAt = applied.appliedAt ? new Date(applied.appliedAt) : null;
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border border-border p-2">
      <p>
        <span className="text-muted">{t("appliedLabel")} </span>
        <span className="text-foreground">{t(`applied.${applied.state}`)}</span>
        {appliedAt && !Number.isNaN(appliedAt.getTime()) ? (
          <span className="text-muted"> · {appliedAt.toLocaleString()}</span>
        ) : null}
        {dirty ? <span className="text-muted"> · {t("unsaved")}</span> : null}
      </p>
      {applied.error ? <p role="alert" className="w-full text-foreground">{applied.error}</p> : null}
      <button className="border border-border px-2 py-0.5 hover:bg-code-bg" onClick={onRefresh} disabled={busy}>
        {t("refresh")}
      </button>
    </div>
  );
}

function ModePicker({
  mode,
  onChange,
}: {
  readonly mode: NetworkPolicyMode;
  readonly onChange: (mode: NetworkPolicyMode) => void;
}) {
  const t = useTranslations("dashboard.cloud.network");
  return (
    <fieldset>
      <legend className="mb-2 font-medium">{t("modeLabel")}</legend>
      <div className="grid gap-2 sm:grid-cols-3">
        {MODES.map((value) => (
          <label
            key={value}
            className={`cursor-pointer border p-2 ${mode === value ? "border-foreground" : "border-border hover:bg-code-bg"}`}
          >
            <input
              type="radio"
              name="network-mode"
              value={value}
              checked={mode === value}
              onChange={() => onChange(value)}
              className="sr-only"
            />
            <span className="block font-medium text-foreground">{t(`mode.${value}.label`)}</span>
            <span className="mt-1 block text-muted">{t(`mode.${value}.description`)}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

function AllowlistEditor({
  policy,
  presets,
  saveError,
  onChange,
}: {
  readonly policy: NetworkPolicy;
  readonly presets: readonly NetworkPolicyPreset[];
  readonly saveError: FieldError | null;
  readonly onChange: (policy: NetworkPolicy) => void;
}) {
  const t = useTranslations("dashboard.cloud.network");
  function togglePreset(id: string) {
    const presetIds = policy.presets.includes(id)
      ? policy.presets.filter((preset) => preset !== id)
      : [...policy.presets, id];
    onChange({ ...policy, presets: presetIds });
  }
  return (
    <>
      <section>
        <h3 className="mb-2 font-medium">{t("presetsTitle")}</h3>
        <div className="flex flex-wrap gap-2">
          {presets.map((preset) => {
            const on = policy.presets.includes(preset.id);
            return (
              <button
                key={preset.id}
                type="button"
                aria-pressed={on}
                title={preset.domains.join(", ")}
                onClick={() => togglePreset(preset.id)}
                className={`border px-2 py-1 ${on ? "border-foreground bg-foreground text-background" : "border-border hover:bg-code-bg"}`}
              >
                {preset.label}
              </button>
            );
          })}
        </div>
        <p className="mt-2 text-muted">{t("presetsNote")}</p>
      </section>
      <DomainList policy={policy} saveError={saveError} onChange={onChange} />
      <RangeList policy={policy} saveError={saveError} onChange={onChange} />
      <label className="flex items-start gap-2">
        <input
          type="checkbox"
          checked={policy.allowDns}
          onChange={(event) => onChange({ ...policy, allowDns: event.target.checked })}
          className="mt-0.5"
        />
        <span>
          <span className="block font-medium text-foreground">{t("dnsLabel")}</span>
          <span className="block text-muted">{t("dnsNote")}</span>
        </span>
      </label>
    </>
  );
}

/** The save error for one list entry, when the API anchored it there. */
function entryError(saveError: FieldError | null, list: "domains" | "ranges", index: number): string | null {
  if (!saveError) return null;
  const match = saveError.path.match(/^(domains|ranges)\.(\d+)/);
  return match && match[1] === list && Number(match[2]) === index ? saveError.message : null;
}

function DomainList({
  policy,
  saveError,
  onChange,
}: {
  readonly policy: NetworkPolicy;
  readonly saveError: FieldError | null;
  readonly onChange: (policy: NetworkPolicy) => void;
}) {
  const t = useTranslations("dashboard.cloud.network");
  const [input, setInput] = useState("");
  const [addError, setAddError] = useState<string | null>(null);

  function add() {
    if (!input.trim()) return;
    const result = tryPolicy({ ...policy, domains: [...policy.domains, input] });
    if ("error" in result) {
      setAddError(result.error.message);
      return;
    }
    onChange({ ...policy, domains: result.policy.domains });
    setInput("");
    setAddError(null);
  }

  return (
    <section>
      <h3 className="mb-1 font-medium">{t("domainsTitle")}</h3>
      <p className="mb-2 text-muted">{t("domainsNote")}</p>
      <ul className="divide-y divide-border border border-border empty:hidden">
        {policy.domains.map((domain, index) => (
          <li key={domain} className="px-2 py-1.5">
            <div className="flex items-center justify-between gap-2">
              <code className="break-all">{domain}</code>
              <button
                className="text-muted hover:text-foreground"
                onClick={() => onChange({ ...policy, domains: policy.domains.filter((_, i) => i !== index) })}
              >
                {t("remove")}
              </button>
            </div>
            <InlineError message={entryError(saveError, "domains", index)} />
          </li>
        ))}
      </ul>
      <form className="mt-2 flex gap-2" onSubmit={(event) => { event.preventDefault(); add(); }}>
        <input
          value={input}
          onChange={(event) => { setInput(event.target.value); setAddError(null); }}
          placeholder="api.example.com"
          aria-label={t("domainInput")}
          className="min-w-0 flex-1 border border-border bg-background px-2 py-1 text-foreground"
        />
        <button className="border border-border px-2 py-1 hover:bg-code-bg">{t("add")}</button>
      </form>
      <InlineError message={addError} />
    </section>
  );
}

function RangeList({
  policy,
  saveError,
  onChange,
}: {
  readonly policy: NetworkPolicy;
  readonly saveError: FieldError | null;
  readonly onChange: (policy: NetworkPolicy) => void;
}) {
  const t = useTranslations("dashboard.cloud.network");
  const [addError, setAddError] = useState<string | null>(null);

  function add(formData: FormData) {
    const range = rangeFromForm(formData);
    if (!range) return;
    const result = tryPolicy({ ...policy, ranges: [...policy.ranges, range] });
    if ("error" in result) {
      setAddError(result.error.message);
      return false;
    }
    onChange({ ...policy, ranges: result.policy.ranges });
    setAddError(null);
    return true;
  }

  return (
    <section>
      <h3 className="mb-1 font-medium">{t("rangesTitle")}</h3>
      <p className="mb-2 text-muted">{t("rangesNote")}</p>
      <ul className="divide-y divide-border border border-border empty:hidden">
        {policy.ranges.map((range, index) => (
          <li key={`${range.cidr}|${range.port ?? ""}|${range.protocol ?? ""}`} className="px-2 py-1.5">
            <div className="flex items-center justify-between gap-2">
              <span className="min-w-0 break-all">
                <code>{range.cidr}</code>
                <span className="text-muted">
                  {" "}{range.port ? `${range.protocol ?? ""}/${range.port}` : t("allPorts")}
                  {range.note ? ` · ${range.note}` : ""}
                </span>
              </span>
              <button
                className="text-muted hover:text-foreground"
                onClick={() => onChange({ ...policy, ranges: policy.ranges.filter((_, i) => i !== index) })}
              >
                {t("remove")}
              </button>
            </div>
            <InlineError message={entryError(saveError, "ranges", index)} />
          </li>
        ))}
      </ul>
      <form
        className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-[2fr_1fr_1fr_2fr_auto]"
        onSubmit={(event) => {
          event.preventDefault();
          const form = event.currentTarget;
          if (add(new FormData(form))) form.reset();
        }}
        onChange={() => setAddError(null)}
      >
        <input name="cidr" placeholder="203.0.113.0/24" aria-label={t("cidrInput")} className="col-span-2 min-w-0 border border-border bg-background px-2 py-1 text-foreground sm:col-span-1" />
        <input name="port" inputMode="numeric" placeholder={t("portInput")} aria-label={t("portInput")} className="min-w-0 border border-border bg-background px-2 py-1 text-foreground" />
        <select name="protocol" aria-label={t("protocolInput")} defaultValue="" className="min-w-0 border border-border bg-background px-2 py-1 text-foreground">
          <option value="">{t("anyProtocol")}</option>
          <option value="tcp">tcp</option>
          <option value="udp">udp</option>
        </select>
        <input name="note" maxLength={120} placeholder={t("noteInput")} aria-label={t("noteInput")} className="col-span-2 min-w-0 border border-border bg-background px-2 py-1 text-foreground sm:col-span-1" />
        <button className="border border-border px-2 py-1 hover:bg-code-bg">{t("add")}</button>
      </form>
      <InlineError message={addError} />
    </section>
  );
}

function rangeFromForm(formData: FormData): NetworkPolicyRange | null {
  const cidr = String(formData.get("cidr") ?? "").trim();
  if (!cidr) return null;
  const portText = String(formData.get("port") ?? "").trim();
  const protocol = String(formData.get("protocol") ?? "");
  const note = String(formData.get("note") ?? "").trim();
  return {
    cidr,
    // A non-numeric port becomes NaN so the shared parser rejects it with its own message.
    ...(portText ? { port: Number(portText) } : {}),
    ...(protocol === "tcp" || protocol === "udp" ? { protocol: protocol as NetworkRangeProtocol } : {}),
    ...(note ? { note } : {}),
  };
}

function RequiredHosts({ domains }: { readonly domains: readonly string[] }) {
  const t = useTranslations("dashboard.cloud.network");
  return (
    <section>
      <h3 className="mb-1 font-medium">{t("requiredTitle")}</h3>
      <p className="mb-2 text-muted">{t("requiredNote")}</p>
      <ul className="flex flex-wrap gap-1">
        {domains.map((domain) => (
          <li key={domain} className="border border-border px-1.5 py-0.5 text-muted"><code>{domain}</code></li>
        ))}
      </ul>
    </section>
  );
}

function InlineError({ message }: { readonly message: string | null }) {
  return message ? <p role="alert" className="mt-1 text-foreground">{message}</p> : null;
}
