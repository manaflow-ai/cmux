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
  return <div className="space-y-4" data-testid="mobile-devices-dashboard">
    {scope.status === "loading" ? <p className="text-muted">{t("loading")}</p> :
      scope.status === "unavailable" ? <p role="alert" className="text-muted">{t("unavailable")}</p> :
        <>
          <label className="block text-xs text-muted" htmlFor="mobile-devices-team">{t("team")}</label>
          <select id="mobile-devices-team" value={scope.selected.id} onChange={event => void scope.switchTeam(scope.teams.find(team => team.id === event.target.value) ?? scope.selected)} className="border border-border bg-background px-2 py-1.5">
            {scope.teams.map(team => <option key={team.id} value={team.id}>{team.name}</option>)}
          </select>
          <ConnectedDevices key={`${userId}:${scope.selected.id}`} teamId={scope.selected.id} userId={userId} stack={stack} />
        </>}
  </div>;
}

/** Each team owns its connection and view state; switching teams unmounts both. */
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
      // Wire errors stay internal. Users get localized recovery guidance.
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
  return <>
    {error ? <div role="alert" className="border border-red-500/40 p-3 text-sm"><p>{error}</p><button className="mt-2 border border-border px-2 py-1" onClick={() => { setDirectory(null); setError(null); setRetryNonce(value => value + 1); }}>{t("retry")}</button></div> : null}
    {!directory && !error ? <p className="text-muted">{t("loading")}</p> : null}
    {directory?.devices.length === 0 ? <p className="border border-border p-3 text-muted">{t("empty")}</p> : null}
    {directory?.canManageTeam ? <RelaySettings key={JSON.stringify(directory.relayURLs)} relayURLs={directory.relayURLs} controllerRef={controllerRef} /> : null}
    {directory?.devices.map(device => <section key={device.deviceRecordId} className="border border-border p-3" data-device-id={device.deviceRecordId}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="font-medium">{device.descriptor.metadata.displayName}</h2>
          <p className="mt-1 text-xs text-muted">{device.descriptor.metadata.platform} · {device.descriptor.metadata.appVersion}</p>
        </div>
        {directory.managedDeviceIds.includes(device.deviceRecordId) ? <button className="border border-border px-2 py-1" disabled={busyDevice === device.deviceRecordId || device.revoked} onClick={() => void revoke(device.deviceRecordId)}>{t("revoke")}</button> : null}
      </div>
      <dl className="mt-3 grid gap-2 text-xs sm:grid-cols-2">
        <Fact label={t("deviceId")} value={`…${device.descriptor.identity.deviceId.slice(-8)}`} />
        <Fact label={t("status")} value={device.revoked ? t("revoked") : t("active")} />
      </dl>
    </section>)}
  </>;
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
  return <section className="border border-border p-3" data-testid="mobile-devices-relay-settings">
    <h2 className="font-medium">{t("relaySettings")}</h2>
    <p className="mt-1 text-xs text-muted">{t("relaySettingsDescription")}</p>
    <textarea className="mt-3 min-h-20 w-full border border-border bg-background p-2 font-mono text-xs" value={draft} onChange={event => setDraft(event.target.value)} aria-label={t("relaySettings")} />
    {failed ? <p role="alert">{t("mutationError")}</p> : null}
    <button className="mt-2 border border-border px-2 py-1" disabled={saving} onClick={() => void save()}>{t("saveRelaySettings")}</button>
  </section>;
}

function Fact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1">{value}</dd></div>;
}
