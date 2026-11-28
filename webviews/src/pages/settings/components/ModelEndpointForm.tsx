import { useId, useMemo, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { ChiefHost } from "../../home-channels/chiefEditing";
import { ALL_MODELS, endpointUrlProblem, failureText, validModel } from "../../shared/byoEndpoint";
import { useNextTarget } from "../../shared/useOwnedEndpoint";
import { useStore } from "../context";
import type { ModelConnection } from "../ops";
import { Icon } from "../icons";
import { azureResource, bedrockRegion, providerCredentials, type OpenAIEndpoint } from "../providerCatalog";
import { t } from "../strings";
import { ConnectionError, ConnectionFooter, ConnectionRegion, SecretField, validKey } from "./ModelConnectionFields";

import { modelEndpointBackend } from "./modelConnections";

const MAX_MODELS = 100;
const azureChatRoute = /\/chat\/completions\/*$/i;
const requestRoute = /\/(?:chat\/completions|completions|responses)\/*$/i;
const cloudflareModel = /^[^@/][^/]*\/[^/]+(?:\/[^/]+)*$/;

function stripRequestRoute(input: string, azure: boolean): string {
  if (/[?#]/.test(input) || !URL.canParse(input.trim())) return input;
  const { pathname } = new URL(input.trim());
  if (!requestRoute.test(pathname) || (azure && azureChatRoute.test(pathname))) return input;
  return input.trimEnd().replace(requestRoute, "");
}

function comparableUrl(input: string): string {
  const url = input.trim();
  return url.includes("?") ? url : url.replace(/\/+$/, "");
}

export function ModelEndpointForm({
  provider,
  saving,
  edit,
  region,
  onRegionChange,
  setSaving,
  onDone,
  onCancel,
}: {
  provider: OpenAIEndpoint;
  saving: boolean;
  edit?: ModelConnection;
  region: string;
  onRegionChange(region: string): void;
  setSaving(saving: boolean): void;
  onDone(): void;
  onCancel(): void;
}) {
  const [original] = useState(edit);
  const existing = original?.endpoint;
  const fields = provider.dialog.fields;
  const editableUrl = fields.includes("url") || (!!existing && !provider.regions && !fields.includes("gateway"));
  const azure = provider.id === "azure";
  const cloudflare = fields.includes("gateway");
  const manualRequired = !!provider.deploymentName || cloudflare;
  const showModels = editableUrl || manualRequired || !provider.defaultModels?.length;
  const kind = existing?.kind ?? "openai-endpoint";
  const store = useStore();
  const service = useMemo(() => new ChiefHost(store.chiefCalls), [store]);
  const targets = useMemo(
    () => ({
      async harnessIds() {
        const profiles = await service.harnessIds();
        const connections = store.getSnapshot().models?.personal.connections ?? [];
        return [...profiles, ...connections.map(({ id }) => id)];
      },
    }),
    [service, store],
  );
  const [typedName, setName] = useState(original?.label ?? (provider.id === "endpoint" ? "" : provider.name));
  const gateway =
    cloudflare && existing
      ? /^https:\/\/gateway\.ai\.cloudflare\.com\/v1\/([a-f0-9]{32})\/([a-z0-9_-]+)\/compat\/*$/i.exec(existing.baseUrl)
      : null;
  const accountTemplate = cloudflare && (!existing || !!gateway) ? provider.baseUrl : null;
  const [accountId, setAccountId] = useState(gateway?.[1] ?? "");
  const [gatewayId, setGatewayId] = useState(gateway?.[2] ?? "default");
  const [base, setBase] = useState(existing?.baseUrl ?? provider.baseUrl ?? "");
  const [regionChanged, setRegionChanged] = useState(false);
  const selectedRegion = provider.regions?.find(({ id }) => id === region);
  const [key, setKey] = useState("");
  const [models, setModels] = useState<string[]>(() => [...(existing?.models ?? provider.defaultModels ?? [])]);
  const [manual, setManual] = useState("");
  const [urlTouched, setUrlTouched] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const savingNow = useRef(false);
  const urlField = useId();
  const urlDescription = useId();
  const modelDescription = useId();
  const busy = saving;
  const validAccountId = /^[a-f0-9]{32}$/i.test(accountId.trim());
  const validGatewayId = /^[a-z0-9_-]+$/i.test(gatewayId.trim());
  const enteredUrl = accountTemplate
    ? validAccountId && validGatewayId
      ? accountTemplate.replace("{ACCOUNT_ID}", accountId.trim()).replace("{GATEWAY_ID}", gatewayId.trim())
      : ""
    : selectedRegion && (!existing || regionChanged)
      ? selectedRegion.baseUrl
      : base.trim();
  const parsed = URL.canParse(enteredUrl) ? new URL(enteredUrl) : null;
  const path = parsed?.pathname ?? "";
  const regionOrResource = azure
    ? azureResource(parsed?.hostname ?? "")
    : provider.id === "bedrock"
      ? bedrockRegion(parsed?.hostname ?? "")
      : undefined;
  const name = !original && regionOrResource ? `${provider.name} (${regionOrResource})` : typedName;
  const currentTarget = original ? { id: original.provider, own: true, typedKey: original.signedIn } : null;
  const next = useNextTarget(original ? null : targets, name, "endpoint", currentTarget);
  const savedQuery = enteredUrl === existing?.baseUrl && enteredUrl.includes("?");
  const urlProblem =
    (azure && !savedQuery && (/\/deployments(?:\/|$)/i.test(path) || azureChatRoute.test(path)) ? "azure" : null) ??
    endpointUrlProblem(enteredUrl, savedQuery) ??
    (/[{}\s]/.test(enteredUrl) ? "invalid" : null);
  const baseUrl =
    !urlProblem && azure && !savedQuery && path === "/" ? enteredUrl.replace(/\/+$/, "") + "/openai/v1" : enteredUrl;
  const showUrlProblem = urlProblem === "query" || urlProblem === "azure" || (urlTouched && !!urlProblem);
  const sameUrl = !!existing && comparableUrl(baseUrl) === comparableUrl(existing.baseUrl);
  const apiKey = key.trim();
  const keepKey = !!original?.signedIn && sameUrl;
  const canRequest = !urlProblem && (apiKey ? validKey(apiKey) : keepKey || !provider.keyRequired || savedQuery);
  const model = manual.trim();
  const invalidModel =
    !!model && (/[,*]/.test(model) || !validModel(model) || (cloudflare && !cloudflareModel.test(model)));
  const duplicateModel = !!model && models.includes(model);
  const canAddModel = !!model && !invalidModel && !duplicateModel && models.length < MAX_MODELS;
  const selectedModels = canAddModel ? [...models, model] : models;
  const canConnect =
    canRequest &&
    !!name.trim() &&
    !invalidModel &&
    (!model || canAddModel) &&
    new TextEncoder().encode(name.trim()).length <= 100 &&
    (selectedModels.length > 0 || !manualRequired) &&
    !!next.target;
  const addModel = () => {
    if (!canAddModel) return;
    setModels([...models, model]);
    setManual("");
  };

  const resetCredentials = () => {
    setKey("");
    setModels([...(provider.defaultModels ?? [])]);
    setManual("");
    setFailure(null);
  };

  const connect = async () => {
    if (savingNow.current || busy || !canConnect || !next.target) return;
    const target = next.target;
    savingNow.current = true;
    setSaving(true);
    setFailure(null);
    try {
      await service.addBackend({
        ...modelEndpointBackend(
          {
            kind,
            name,
            baseUrl,
            apiKey,
            models: selectedModels.length ? selectedModels.join(",") : ALL_MODELS,
          },
          target,
          {
            preset: kind === "openai-endpoint" ? provider.id : undefined,
            revision: existing?.revision,
          },
        ),
        validateEndpoint: cloudflare && !savedQuery && (!original || !!apiKey || !sameUrl),
      });
      await store.refreshModels();
      onDone();
    } catch (error) {
      const code = (error as { code?: string } | null)?.code;
      const message = failureText(error);
      const regionName = selectedRegion ? t(selectedRegion.label) : regionOrResource;
      if (code === "cmux.agents.endpoint_check" && regionName && /HTTP 40[13]/.test(message)) {
        setFailure(t("settingsWindow.models.endpoint.regionKeyRefused", regionName));
      } else if (
        code === "cmux.agents.invalid" ||
        code === "cmux.protocol.invalid_params" ||
        code === "cmux.agents.secret_inline"
      ) {
        setFailure(t("settingsWindow.models.endpoint.invalidConnection"));
      } else if (code === "cmux.agents.failed" || code === "cmux.agents.not_found") {
        setFailure(t("settingsWindow.models.endpoint.saveFailed"));
      } else {
        setFailure(message);
      }
      next.refresh();
    } finally {
      savingNow.current = false;
      setSaving(false);
    }
  };

  return (
    <form
      className="models-form"
      data-models-endpoint-form=""
      noValidate
      aria-busy={busy}
      onSubmit={(event) => {
        event.preventDefault();
        void connect();
      }}
    >
      {(fields.includes("name") || original) && (
        <label className="models-field">
          <span>{t("settingsPage.agents.name")}</span>
          <Input
            className="field"
            type="text"
            value={name}
            maxLength={64}
            disabled={busy}
            onChange={(event) => setName(event.target.value)}
          />
        </label>
      )}
      <ConnectionRegion
        provider={provider}
        value={region}
        disabled={busy}
        onChange={(value) => {
          onRegionChange(value);
          setRegionChanged(true);
          resetCredentials();
        }}
      />
      {accountTemplate && (
        <label className="models-field">
          <span>{t("settingsWindow.models.endpoint.accountId")}</span>
          <Input
            className="field"
            value={accountId}
            maxLength={32}
            autoComplete="off"
            spellCheck={false}
            disabled={busy}
            aria-invalid={(accountId.length > 0 && !validAccountId) || undefined}
            onChange={(event) => {
              setAccountId(event.target.value);
              resetCredentials();
            }}
          />
        </label>
      )}
      {accountTemplate && (
        <label className="models-field">
          <span>{t("settingsWindow.models.dialog.gatewayId")}</span>
          <Input
            className="field"
            value={gatewayId}
            maxLength={64}
            autoComplete="off"
            spellCheck={false}
            disabled={busy}
            aria-invalid={(gatewayId.length > 0 && !validGatewayId) || undefined}
            onChange={(event) => {
              setGatewayId(event.target.value);
              resetCredentials();
            }}
          />
        </label>
      )}
      {editableUrl && (
        <div className="models-field">
          <label htmlFor={urlField}>{t("settingsPage.agents.endpoint.baseUrl")}</label>
          <Input
            id={urlField}
            aria-describedby={showUrlProblem ? urlDescription : undefined}
            className="field"
            type="url"
            placeholder={provider.urlHint}
            value={base}
            spellCheck={false}
            autoComplete="off"
            maxLength={2048}
            disabled={busy}
            aria-invalid={showUrlProblem || undefined}
            onBlur={() => setUrlTouched(true)}
            onChange={(event) => {
              const input = stripRequestRoute(event.target.value, azure);
              setBase(input);
              if (comparableUrl(input) === comparableUrl(baseUrl)) return;
              resetCredentials();
            }}
          />
          {showUrlProblem && (
            <small id={urlDescription} className="row-error" role="alert">
              {t(
                urlProblem === "azure"
                  ? "settingsWindow.models.endpoint.azureBaseUrl"
                  : urlProblem === "query"
                    ? "settingsWindow.models.endpoint.noQuery"
                    : urlProblem === "insecure"
                      ? "settingsPage.agents.endpoint.insecure"
                      : "settingsWindow.models.endpoint.invalidUrl",
              )}
            </small>
          )}
        </div>
      )}
      <SecretField
        label={t(
          cloudflare
            ? "settingsWindow.models.dialog.apiToken"
            : provider.keyRequired
              ? "settingsWindow.models.key.field"
              : "settingsPage.agents.endpoint.apiKeyOptional",
        )}
        placeholder={original ? undefined : providerCredentials(provider).placeholder}
        help={original?.signedIn && sameUrl ? t("settingsWindow.models.key.keep") : undefined}
        value={key}
        disabled={busy}
        onChange={(next) => {
          setKey(next);
          setFailure(null);
        }}
      />
      {showModels && (
        <div className="models-endpoint-models">
          {models.length > 0 && (
            <ul className="models-model-list">
              {models.map((id) => (
                <li key={id}>
                  <span>{id}</span>
                  <Button
                    type="button"
                    className="models-icon-button"
                    variant="ghost"
                    disabled={busy}
                    aria-label={t("settingsWindow.models.endpoint.removeModel", id)}
                    onClick={() => setModels(models.filter((model) => model !== id))}
                  >
                    <Icon name="xmark" />
                  </Button>
                </li>
              ))}
            </ul>
          )}
          <div className="models-manual-model">
            <label className="models-field">
              <span>
                {t(
                  provider.deploymentName
                    ? "settingsWindow.models.endpoint.deploymentName"
                    : "settingsWindow.models.endpoint.modelId",
                )}
              </span>
              <Input
                className="field"
                type="text"
                value={manual}
                placeholder={cloudflare ? "vendor/model" : undefined}
                disabled={busy}
                aria-invalid={invalidModel || duplicateModel || undefined}
                aria-describedby={invalidModel || duplicateModel ? modelDescription : undefined}
                onChange={(event) => setManual(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && !event.nativeEvent.isComposing) {
                    event.preventDefault();
                    addModel();
                  }
                }}
              />
              {invalidModel || duplicateModel ? (
                <small id={modelDescription} className="row-error" role="alert">
                  {t(
                    duplicateModel
                      ? "settingsWindow.models.endpoint.duplicateModel"
                      : cloudflare
                        ? "settingsWindow.models.endpoint.cloudflareModel"
                        : "settingsWindow.models.endpoint.invalidModel",
                  )}
                </small>
              ) : null}
            </label>
            <Button type="button" className="button" disabled={busy || !canAddModel} onClick={addModel}>
              {t("settingsWindow.models.endpoint.addModel")}
            </Button>
          </div>
        </div>
      )}
      {models.length === MAX_MODELS && <p className="row-help">{t("settingsWindow.models.endpoint.listLimit")}</p>}
      {provider.id === "bedrock" && apiKey.startsWith("bedrock-api-key-") && (
        <p className="row-help">{t("settingsWindow.models.endpoint.bedrockShortTerm")}</p>
      )}
      {(failure || next.failed) && <ConnectionError>{failure ?? next.failed}</ConnectionError>}
      <ConnectionFooter
        onClose={onCancel}
        disabled={!canConnect}
        busy={busy}
        loading={saving}
        label={original ? t("settingsWindow.density.save") : undefined}
        failed={!!(failure || next.failed)}
        connectAction="addEndpoint"
      />
    </form>
  );
}
