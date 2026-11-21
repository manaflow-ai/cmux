// Settings > Cloud > Cloud Credentials (keyless cloud credentials, https://github.com/manaflow-ai/cmux/issues/48427):
// the team's cmux OIDC issuer (`cmux.settings.cloudCredentials.state`: the app reads cmux-platform's
// /v1/cloud/oidc/info with the person's session) and, per cloud, the steps that make it trust the team's machines.
// A Cloud machine keeps a short-lived token at /run/cmux-oidc/token once its audience marker exists (cmux-host
// oidc_token.rs); nothing here holds or shows a token. Read when the card mounts and on Refresh; it does not poll.
//
// Two layouts for review (a new design gets two variants; Lawrence picks): `rows` lists each cloud as a disclosure
// row, `tabs` shows one cloud at a time behind a segmented control. The page ships `rows`.
import { useCallback, useEffect, useState } from "react";
import { Button } from "../../../ui/Button";
import { Disclosure } from "../../../ui/Disclosure";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { CLOUD_CREDENTIALS_PROVIDERS, setupSteps, type CloudCredentialsProvider } from "../cloudCredentials";
import { useStore } from "../context";
import type { CloudCredentialsInfo, CloudCredentialsState } from "../ops";
import { t } from "../strings";

export type CloudCredentialsLayout = "rows" | "tabs";

/** Each cloud's name: the provider's own product names stay as they are; the last row is ours. */
const PROVIDER_NAME: Record<CloudCredentialsProvider, () => string> = {
  aws: () => "AWS",
  gcp: () => "Google Cloud",
  azure: () => "Azure",
  vault: () => "HashiCorp Vault",
  generic: () => t("settingsPage.cloudCredentials.generic"),
};

function CopyRow({ title, value, id }: { title: string; value: string; id: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="row" data-credentials-url={id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{title}</div>
          <div className="row-help select-text break-all" data-credentials-value="">
            <code className="font-mono">{value}</code>
          </div>
        </div>
        <Button
          className="button"
          data-credentials-copy={id}
          onClick={() => {
            void navigator.clipboard?.writeText(value).then(() => setCopied(true));
          }}
        >
          {copied ? t("settingsPage.cloudCredentials.copied") : t("settingsPage.cloudCredentials.copy")}
        </Button>
      </div>
    </div>
  );
}

function ProviderSteps({ provider, info }: { provider: CloudCredentialsProvider; info: CloudCredentialsInfo }) {
  return (
    // min-w-0 down to the <pre>: a flex or grid child is as wide as its longest line unless told
    // otherwise, so without it a long policy line widens the card instead of scrolling in its block.
    <div className="flex min-w-0 flex-col gap-2 pb-2" data-credentials-steps={provider}>
      <p className="m-0 text-detail text-muted">{t(`settingsPage.cloudCredentials.${provider}.help`)}</p>
      {setupSteps(provider, info).map((step) => (
        <div key={step.where} className="min-w-0" data-credentials-step={step.where}>
          <div className="row-title">
            {step.where === "cloud"
              ? t("settingsPage.cloudCredentials.inYourCloud")
              : t("settingsPage.cloudCredentials.onTheMachine")}
          </div>
          <pre className="m-0 mt-1 max-w-full overflow-x-auto rounded-md border border-solid border-edge p-2 font-mono text-detail text-fg select-text">
            <code>{step.code}</code>
          </pre>
        </div>
      ))}
    </div>
  );
}

/** The issuer's URLs and every cloud's steps for one team, in one of the layouts. */
export function CloudCredentialsBody({
  info,
  layout = "rows",
}: {
  info: CloudCredentialsInfo;
  layout?: CloudCredentialsLayout;
}) {
  return (
    <>
      <div className="rows">
        <CopyRow id="issuer" title={t("settingsPage.cloudCredentials.issuer")} value={info.issuer} />
        <CopyRow id="discovery" title={t("settingsPage.cloudCredentials.discovery")} value={info.discovery_url} />
        <CopyRow id="jwks" title={t("settingsPage.cloudCredentials.jwks")} value={info.jwks_url} />
        <CopyRow id="subject" title={t("settingsPage.cloudCredentials.subject")} value={info.subject_format} />
      </div>
      {/* The space sits on a wrapper: .group-title's own margin outranks a utility on the heading. */}
      <div className="pt-4">
        <h4 className="group-title">{t("settingsPage.cloudCredentials.connect")}</h4>
      </div>
      {layout === "tabs" ? (
        <Tabs variant="segmented" defaultValue="aws" className="min-w-0" data-credentials-layout="tabs">
          <TabsList>
            {CLOUD_CREDENTIALS_PROVIDERS.map((p) => (
              <TabsTrigger key={p} value={p} data-credentials-provider={p}>
                {PROVIDER_NAME[p]()}
              </TabsTrigger>
            ))}
          </TabsList>
          {CLOUD_CREDENTIALS_PROVIDERS.map((p) => (
            <TabsContent key={p} value={p}>
              <ProviderSteps provider={p} info={info} />
            </TabsContent>
          ))}
        </Tabs>
      ) : (
        <div className="rows" data-credentials-layout="rows">
          {CLOUD_CREDENTIALS_PROVIDERS.map((p) => (
            <div className="row min-w-0" key={p} data-credentials-provider={p}>
              <Disclosure label={PROVIDER_NAME[p]()}>
                <ProviderSteps provider={p} info={info} />
              </Disclosure>
            </div>
          ))}
        </div>
      )}
    </>
  );
}

/** The card for one state: `null` while the first read runs, signed out, the issuer, or the API's refusal. */
export function CloudCredentialsView({
  state,
  layout = "rows",
  busy = false,
  onRefresh,
}: {
  state: CloudCredentialsState | null;
  layout?: CloudCredentialsLayout;
  busy?: boolean;
  onRefresh: () => void;
}) {
  return (
    <section className="group" data-card="cloudCredentials">
      <h3 className="group-title">{t("settingsPage.cloudCredentials.title")}</h3>
      <p className="row-help">{t("settingsPage.cloudCredentials.help")}</p>
      {state === null ? null : !state.available ? (
        <div className="row" data-credentials-unavailable="">
          <div className="row-main">
            <span className="row-label">
              <span className="row-help">{t("settingsPage.cloudCredentials.unavailable")}</span>
            </span>
          </div>
        </div>
      ) : state.info ? (
        <CloudCredentialsBody info={state.info} layout={layout} />
      ) : (
        <div className="row" data-credentials-error={state.error ?? ""}>
          <div className="row-main">
            <span className="row-label">
              <span className="row-help">{t("settingsPage.cloudCredentials.error")}</span>
            </span>
            <span className="row-control">
              <Button
                type="button"
                className="button"
                disabled={busy}
                data-credentials-refresh=""
                onClick={onRefresh}
              >
                {t("settingsPage.cloudCredentials.refresh")}
              </Button>
            </span>
          </div>
        </div>
      )}
    </section>
  );
}

export function CloudCredentialsCard({ layout = "rows" }: { layout?: CloudCredentialsLayout }) {
  const store = useStore();
  const [state, setState] = useState<CloudCredentialsState | null>(null);
  const [busy, setBusy] = useState(false);
  const refresh = useCallback(async () => {
    setBusy(true);
    try {
      setState(await store.cloudCredentials());
    } finally {
      setBusy(false);
    }
  }, [store]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  return <CloudCredentialsView state={state} layout={layout} busy={busy} onRefresh={() => void refresh()} />;
}
