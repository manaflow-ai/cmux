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

  return <div className="space-y-5" data-testid="mobile-devices-dashboard">
    {scope.status === "loading" ? <p className="text-muted">{t("loading")}</p> :
      scope.status === "unavailable" ? <p role="alert" className="text-muted">{t("unavailable")}</p> :
        <>
          <p className="text-xs text-muted">{t("team")}: {scope.selected.name}</p>
          <ConnectedDevices key={`${userId}:${scope.selected.id}`} teamId={scope.selected.id} userId={userId} stack={stack} />
        </>}
  </div>;
}

/** Each team owns its connection and view state; the shell owns team switching. */
function ConnectedDevices({ teamId, userId, stack }: { readonly teamId: string; readonly userId: string; readonly stack: ReturnType<typeof useStackApp> }) {
  const t = useTranslations("dashboard.mobileDevices");
  const [directory, setDirectory] = useState<DashboardDirectory | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [revokeError, setRevokeError] = useState<string | null>(null);
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
    setBusyDevice(deviceId); setRevokeError(null);
    try { await controller.revoke(deviceId); }
    catch { setRevokeError(deviceId); }
    finally { setBusyDevice(null); }
  };
  const managedDeviceIds = new Set(directory?.managedDeviceIds ?? []);
  return <>
    {error ? <ConnectionError message={error} onRetry={() => { setDirectory(null); setError(null); setRetryNonce(value => value + 1); }} /> : null}
    {!directory && !error ? <LoadingState label={t("loading")} /> : null}
    {directory ? <>
      {directory.devices.length === 0 ? <EmptyDevices /> : <div className="divide-y divide-border border-y border-border">
        {directory.devices.map(device => <DeviceCard
          key={device.deviceRecordId}
          device={device}
          canRevoke={managedDeviceIds.has(device.deviceRecordId)}
          busy={busyDevice === device.deviceRecordId}
          failed={revokeError === device.deviceRecordId}
          onRevoke={() => void revoke(device.deviceRecordId)}
        />)}
      </div>}
      {directory.canManageTeam ? <RelaySettings key={JSON.stringify(directory.relayURLs)} relayURLs={directory.relayURLs} controllerRef={controllerRef} /> : null}
    </> : null}
  </>;
}

function DeviceCard({ device, canRevoke, busy, failed, onRevoke }: {
  readonly device: DashboardDirectory["devices"][number];
  readonly canRevoke: boolean;
  readonly busy: boolean;
  readonly failed: boolean;
  readonly onRevoke: () => void;
}) {
  const t = useTranslations("dashboard.mobileDevices");
  const { displayName, platform, appVersion } = device.descriptor.metadata;
  return <section className="py-3" data-device-id={device.deviceRecordId}>
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div className="min-w-0">
        <h2 className="truncate font-medium">{displayName}</h2>
        <p className="mt-1 text-xs text-muted">{platform} · {appVersion} · {device.revoked ? t("revoked") : t("active")}</p>
      </div>
      {canRevoke ? <button type="button" className="shrink-0 text-xs text-muted underline decoration-border underline-offset-4 hover:text-foreground disabled:cursor-not-allowed disabled:opacity-50" disabled={busy || device.revoked} onClick={onRevoke}>{busy ? t("revoking") : t("revoke")}</button> : null}
    </div>
    <dl className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-xs text-muted">
      <Fact label={t("deviceId")} value={`…${device.descriptor.identity.deviceId.slice(-8)}`} />
      <Fact label={t("revision")} value={`#${device.revision}`} />
    </dl>
    {failed ? <p role="alert" className="mt-2 text-xs text-red-600 dark:text-red-400">{t("mutationError")}</p> : null}
  </section>;
}

function EmptyDevices() {
  const t = useTranslations("dashboard.mobileDevices");
  return <div className="border-y border-border py-4">
    <h2 className="font-medium">{t("emptyTitle")}</h2>
    <p className="mt-1 text-sm text-muted">{t("emptyDescription")}</p>
  </div>;
}

function LoadingState({ label }: { readonly label: string }) {
  return <div className="space-y-3" role="status" aria-label={label}>
    <p className="text-sm text-muted">{label}</p>
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
  return <details className="border-t border-border pt-3" data-testid="mobile-devices-relay-settings">
    <summary className="cursor-pointer text-sm font-medium">{t("relaySettings")}</summary>
    <p className="mt-2 text-xs text-muted">{t("relaySettingsDescription")}</p>
    <textarea className="mt-3 min-h-20 w-full border border-border bg-background p-2 font-mono text-xs outline-none focus:border-foreground" value={draft} onChange={event => setDraft(event.target.value)} aria-label={t("relaySettings")} />
    <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
      {failed ? <p role="alert" className="text-xs text-red-600 dark:text-red-400">{t("mutationError")}</p> : <span />}
      <button type="button" className="border border-border px-2 py-1 text-xs hover:bg-code-bg disabled:cursor-not-allowed disabled:opacity-50" disabled={saving} onClick={() => void save()}>{saving ? t("savingRelaySettings") : t("saveRelaySettings")}</button>
    </div>
  </details>;
}

function Fact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="sr-only">{label}</dt><dd><span className="text-muted">{label} </span><span className="font-mono text-foreground">{value}</span></dd></div>;
}
