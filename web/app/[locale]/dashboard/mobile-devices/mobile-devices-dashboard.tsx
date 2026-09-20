"use client";

import { useStackApp } from "@hexclave/next";
import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { useDashboardTeamScope } from "../dashboard-team-scope";
import { V2DashboardController, type DashboardDirectory } from "./v2-dashboard-controller";

const PROJECT_ID = process.env.NEXT_PUBLIC_STACK_PROJECT_ID ?? "";
const DEFAULT_ENVIRONMENT = process.env.NEXT_PUBLIC_IROH_V2_ENVIRONMENT ??
  (process.env.NODE_ENV === "production" ? "production" : "development");
const DEFAULT_ORIGIN = process.env.NEXT_PUBLIC_IROH_V2_ORIGIN ??
  `https://cmux-iroh-v2${DEFAULT_ENVIRONMENT === "production" ? "" : `-${DEFAULT_ENVIRONMENT}`}.debussy.workers.dev`;

type Props = { readonly userId: string };

export function MobileDevicesDashboard({ userId }: Props) {
  const t = useTranslations("dashboard.mobileDevices");
  const stack = useStackApp();
  const scope = useDashboardTeamScope(userId);

  return <div className="space-y-6" data-testid="mobile-devices-dashboard">
    {scope.status === "loading" ? <p className="text-muted">{t("loading")}</p> :
      scope.status === "unavailable" ? <p role="alert" className="text-muted">{t("unavailable")}</p> :
        <>
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border pb-4">
            <div>
              <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">{t("team")}</p>
              <p className="mt-1 font-medium">{scope.selected.name}</p>
            </div>
            <span className="inline-flex items-center gap-2 border border-border bg-code-bg px-2.5 py-1.5 text-xs text-muted">
              <span className="size-1.5 rounded-full bg-emerald-500" aria-hidden="true" />
              {t("scopeActive")}
            </span>
          </div>
          <ConnectedDevices key={`${userId}:${scope.selected.id}`} teamId={scope.selected.id} userId={userId} stack={stack} />
        </>}
  </div>;
}

/** Each team owns its connection and view state; the shell owns team switching. */
function ConnectedDevices({ teamId, userId, stack }: { readonly teamId: string; readonly userId: string; readonly stack: ReturnType<typeof useStackApp> }) {
  const t = useTranslations("dashboard.mobileDevices");
  const [directory, setDirectory] = useState<DashboardDirectory | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [retryNonce, setRetryNonce] = useState(0);
  const [busyDevice, setBusyDevice] = useState<string | null>(null);
  const controllerRef = useRef<V2DashboardController | null>(null);
  const unavailable = t("unavailable");

  useEffect(() => {
    let cancelled = false;
    const controller = new V2DashboardController({
      origin: DEFAULT_ORIGIN, environment: DEFAULT_ENVIRONMENT, projectId: PROJECT_ID, userId, teamId,
      getStackToken: async () => (await stack.getAuthJson()).accessToken,
      onDirectory: next => { if (!cancelled) { setDirectory(next); setError(null); } },
      onError: () => { if (!cancelled) setError(unavailable); },
    });
    controllerRef.current = controller;
    void controller.start();
    return () => {
      cancelled = true;
      controllerRef.current = null;
      void controller.stop();
    };
  }, [retryNonce, stack, teamId, userId, unavailable]);

  const revoke = async (deviceId: string) => {
    const controller = controllerRef.current;
    if (!controller) return;
    setBusyDevice(deviceId); setError(null);
    try { await controller.revoke(deviceId); }
    catch { setError(t("mutationError")); }
    finally { setBusyDevice(null); }
  };
  const managedDeviceIds = new Set(directory?.managedDeviceIds ?? []);
  return <>
    {error ? <ConnectionError message={error} onRetry={() => { setDirectory(null); setError(null); setRetryNonce(value => value + 1); }} /> : null}
    {!directory && !error ? <LoadingState label={t("loading")} /> : null}
    {directory ? <>
      <DeviceSummary directory={directory} />
      {directory.devices.length === 0 ? <EmptyDevices /> : <div className="grid gap-3 lg:grid-cols-2">
        {directory.devices.map(device => <DeviceCard
          key={device.deviceRecordId}
          device={device}
          canRevoke={managedDeviceIds.has(device.deviceRecordId)}
          busy={busyDevice === device.deviceRecordId}
          onRevoke={() => void revoke(device.deviceRecordId)}
        />)}
      </div>}
      {directory.canManageTeam ? <RelaySettings key={JSON.stringify(directory.relayURLs)} relayURLs={directory.relayURLs} controllerRef={controllerRef} /> : null}
    </> : null}
  </>;
}

function DeviceSummary({ directory }: { readonly directory: DashboardDirectory }) {
  const t = useTranslations("dashboard.mobileDevices");
  const activeCount = directory.devices.filter(device => !device.revoked).length;
  return <div className="grid gap-px border border-border bg-border sm:grid-cols-3" data-testid="mobile-devices-summary">
    <SummaryMetric label={t("registeredDevices")} value={directory.devices.length.toString()} />
    <SummaryMetric label={t("activeDevices")} value={activeCount.toString()} />
    <SummaryMetric label={t("directoryRevision")} value={`#${directory.revision}`} />
  </div>;
}

function SummaryMetric({ label, value }: { readonly label: string; readonly value: string }) {
  return <div className="bg-background px-4 py-3">
    <p className="text-xs text-muted">{label}</p>
    <p className="mt-1 font-mono text-lg tabular-nums">{value}</p>
  </div>;
}

function DeviceCard({ device, canRevoke, busy, onRevoke }: {
  readonly device: DashboardDirectory["devices"][number];
  readonly canRevoke: boolean;
  readonly busy: boolean;
  readonly onRevoke: () => void;
}) {
  const t = useTranslations("dashboard.mobileDevices");
  const { displayName, platform, appVersion } = device.descriptor.metadata;
  return <section className="group border border-border bg-background p-4 transition-colors hover:border-foreground/40" data-device-id={device.deviceRecordId}>
    <div className="flex items-start gap-3">
      <DeviceGlyph platform={platform} />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div className="min-w-0">
            <h2 className="truncate font-medium">{displayName}</h2>
            <p className="mt-1 text-xs text-muted">{platform} <span aria-hidden="true">·</span> {appVersion}</p>
          </div>
          <StatusBadge revoked={device.revoked} />
        </div>
      </div>
    </div>
    <dl className="mt-5 grid gap-3 border-t border-border pt-3 text-xs sm:grid-cols-2">
      <Fact label={t("deviceId")} value={`…${device.descriptor.identity.deviceId.slice(-8)}`} />
      <Fact label={t("revision")} value={`#${device.revision}`} />
    </dl>
    {canRevoke ? <div className="mt-4 flex justify-end border-t border-border pt-3">
      <button type="button" className="text-xs text-muted underline decoration-border underline-offset-4 hover:text-foreground disabled:cursor-not-allowed disabled:opacity-50" disabled={busy || device.revoked} onClick={onRevoke}>{busy ? t("revoking") : t("revoke")}</button>
    </div> : null}
  </section>;
}

function DeviceGlyph({ platform }: { readonly platform: string }) {
  return <span className="flex size-9 shrink-0 items-center justify-center border border-border bg-code-bg text-muted" aria-hidden="true">
    {platform.toLowerCase().includes("phone") || platform.toLowerCase().includes("ios") ? <PhoneIcon /> : <MonitorIcon />}
  </span>;
}

function StatusBadge({ revoked }: { readonly revoked: boolean }) {
  const t = useTranslations("dashboard.mobileDevices");
  return <span className={`inline-flex items-center gap-1.5 px-2 py-1 text-[11px] font-medium ${revoked ? "bg-code-bg text-muted" : "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"}`}>
    <span className={`size-1.5 rounded-full ${revoked ? "bg-muted" : "bg-emerald-500"}`} aria-hidden="true" />
    {revoked ? t("revoked") : t("active")}
  </span>;
}

function EmptyDevices() {
  const t = useTranslations("dashboard.mobileDevices");
  return <div className="border border-dashed border-border px-5 py-12 text-center">
    <span className="mx-auto flex size-12 items-center justify-center border border-border bg-code-bg text-muted" aria-hidden="true"><DevicesIcon /></span>
    <h2 className="mt-4 font-medium">{t("emptyTitle")}</h2>
    <p className="mx-auto mt-2 max-w-md text-sm text-muted">{t("emptyDescription")}</p>
  </div>;
}

function LoadingState({ label }: { readonly label: string }) {
  return <div className="space-y-3" aria-label={label}>
    <div className="grid gap-px border border-border bg-border sm:grid-cols-3">
      {["one", "two", "three"].map(key => <div key={key} className="h-20 animate-pulse bg-code-bg" />)}
    </div>
    <div className="grid gap-3 lg:grid-cols-2">
      {["one", "two"].map(key => <div key={key} className="h-44 animate-pulse border border-border bg-code-bg" />)}
    </div>
    <p className="text-xs text-muted">{label}</p>
  </div>;
}

function ConnectionError({ message, onRetry }: { readonly message: string; readonly onRetry: () => void }) {
  const t = useTranslations("dashboard.mobileDevices");
  return <div role="alert" className="flex flex-wrap items-center justify-between gap-3 border border-red-500/40 bg-red-500/5 px-4 py-3 text-sm">
    <p>{message}</p>
    <button type="button" className="border border-border bg-background px-3 py-1.5 text-xs hover:bg-code-bg" onClick={onRetry}>{t("retry")}</button>
  </div>;
}

function RelaySettings({ relayURLs, controllerRef }: {
  readonly relayURLs: readonly string[];
  readonly controllerRef: { readonly current: V2DashboardController | null };
}) {
  const t = useTranslations("dashboard.mobileDevices");
  const [draft, setDraft] = useState(relayURLs.join("\n"));
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const save = async () => {
    const controller = controllerRef.current;
    if (!controller) return;
    setSaving(true); setFailed(false);
    try { await controller.updateRelayPreferences(draft.split(/\s+/u).map(value => value.trim()).filter(Boolean)); }
    catch { setFailed(true); }
    finally { setSaving(false); }
  };
  return <section className="border border-border bg-code-bg/40 p-4" data-testid="mobile-devices-relay-settings">
    <div className="flex items-start gap-3">
      <span className="flex size-9 shrink-0 items-center justify-center border border-border bg-background text-muted" aria-hidden="true"><RelayIcon /></span>
      <div>
        <h2 className="font-medium">{t("relaySettings")}</h2>
        <p className="mt-1 text-xs text-muted">{t("relaySettingsDescription")}</p>
      </div>
    </div>
    <textarea className="mt-4 min-h-20 w-full border border-border bg-background p-3 font-mono text-xs outline-none focus:border-foreground" value={draft} onChange={event => setDraft(event.target.value)} aria-label={t("relaySettings")} />
    <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
      {failed ? <p role="alert" className="text-xs text-red-600 dark:text-red-400">{t("mutationError")}</p> : <span />}
      <button type="button" className="border border-foreground bg-foreground px-3 py-1.5 text-xs text-background hover:opacity-80 disabled:cursor-not-allowed disabled:opacity-50" disabled={saving} onClick={() => void save()}>{saving ? t("savingRelaySettings") : t("saveRelaySettings")}</button>
    </div>
  </section>;
}

function Fact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1 break-words font-mono text-foreground">{value}</dd></div>;
}

function PhoneIcon() {
  return <svg viewBox="0 0 16 16" className="size-4" fill="none" stroke="currentColor" strokeWidth="1.2"><rect x="4.5" y="1.5" width="7" height="13" rx="1.5" /><path d="M7 3h2" /><path d="M7.3 12.5h1.4" /></svg>;
}

function MonitorIcon() {
  return <svg viewBox="0 0 16 16" className="size-4" fill="none" stroke="currentColor" strokeWidth="1.2"><rect x="1.5" y="2" width="13" height="9" rx="1" /><path d="M5.5 14h5M8 11v3" /></svg>;
}

function DevicesIcon() {
  return <svg viewBox="0 0 20 20" className="size-5" fill="none" stroke="currentColor" strokeWidth="1.2"><rect x="2.5" y="3" width="11" height="8" rx="1" /><path d="M5.5 14.5h5M8 11v3.5M15 6.5h2.5v10H10v-2" /></svg>;
}

function RelayIcon() {
  return <svg viewBox="0 0 16 16" className="size-4" fill="none" stroke="currentColor" strokeWidth="1.2"><circle cx="3" cy="8" r="1.5" /><circle cx="13" cy="4" r="1.5" /><circle cx="13" cy="12" r="1.5" /><path d="m4.4 7.4 7.2-2.8M4.4 8.6l7.2 2.8" /></svg>;
}
