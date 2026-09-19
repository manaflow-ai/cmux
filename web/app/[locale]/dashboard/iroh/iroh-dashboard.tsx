"use client";

import { useStackApp } from "@stackframe/stack";
import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { useDashboardTeamScope } from "../dashboard-team-scope";
import { V2DashboardController, type DashboardDirectory } from "./v2-dashboard-controller";

const PROJECT_ID = process.env.NEXT_PUBLIC_STACK_PROJECT_ID ?? "";
const DEFAULT_ENVIRONMENT = process.env.NEXT_PUBLIC_IROH_V2_ENVIRONMENT ??
  (process.env.NODE_ENV === "production" ? "production" : "development");
const DEFAULT_ORIGIN = process.env.NEXT_PUBLIC_IROH_V2_ORIGIN ??
  `https://cmux-iroh-v2${DEFAULT_ENVIRONMENT === "production" ? "" : `-${DEFAULT_ENVIRONMENT}`}.debussy.workers.dev`;

type Props = { readonly userId: string };

export function IrohDashboard({ userId }: Props) {
  const t = useTranslations("dashboard.iroh");
  const scope = useDashboardTeamScope(userId);
  if (scope.status === "loading") return <p className="text-muted">{t("loading")}</p>;
  if (scope.status === "unavailable") return <p role="alert" className="text-muted">{t("unavailable")}</p>;
  if (scope.selected.personal) return <p className="text-muted">{t("selectTeam")}</p>;
  return <AuthenticatedIrohDashboard key={scope.selected.id} userId={userId} teamId={scope.selected.id} />;
}

function AuthenticatedIrohDashboard({ userId, teamId }: Props & { readonly teamId: string }) {
  const t = useTranslations("dashboard.iroh");
  const stack = useStackApp();
  const [directory, setDirectory] = useState<DashboardDirectory | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyDevice, setBusyDevice] = useState<string | null>(null);
  const [relayURLsDraft, setRelayURLsDraft] = useState("");
  const [savingRelayURLs, setSavingRelayURLs] = useState(false);
  const controllerRef = useRef<V2DashboardController | null>(null);

  useEffect(() => {
    if (!teamId) return;
    let cancelled = false;
    const controller = new V2DashboardController({
      origin: DEFAULT_ORIGIN,
      environment: DEFAULT_ENVIRONMENT,
      projectId: PROJECT_ID,
      userId,
      teamId,
      getStackToken: async () => (await stack.getAuthJson()).accessToken,
      onDirectory: next => {
        if (!cancelled) {
          setDirectory(next);
          setRelayURLsDraft(next.relayURLs.join("\n"));
          setError(null);
        }
      },
      onError: () => { if (!cancelled) setError(t("connectionError")); },
    });
    controllerRef.current = controller;
    void controller.start();
    return () => {
      cancelled = true;
      if (controllerRef.current === controller) controllerRef.current = null;
      void controller.stop();
    };
  }, [stack, teamId, userId, t]);

  const devices = useMemo(() => directory?.devices ?? [], [directory]);
  const saveRelayURLs = async () => {
    const relayURLs = relayURLsDraft.split(/\s+/u).map(value => value.trim()).filter(Boolean);
    setSavingRelayURLs(true); setError(null);
    try { await controllerRef.current?.updateRelayPreferences(relayURLs); }
    catch (cause) { setError(cause instanceof Error ? cause.message : t("mutationError")); }
    finally { setSavingRelayURLs(false); }
  };
  return (
    <div className="space-y-4" data-testid="iroh-dashboard">
      {error ? <p role="alert" className="border border-red-500/40 p-3 text-sm">{error}</p> : null}
      {!directory && !error ? <p className="text-muted">{t("loading")}</p> : null}
      {directory && devices.length === 0 ? <p className="border border-border p-3 text-muted">{t("empty")}</p> : null}
      {directory?.canManageTeam ? <section className="border border-border p-3" data-testid="iroh-relay-settings">
        <h2 className="font-medium">{t("relaySettings")}</h2>
        <p className="mt-1 text-xs text-muted">{t("relaySettingsDescription")}</p>
        <textarea className="mt-3 min-h-20 w-full border border-border bg-background p-2 font-mono text-xs" value={relayURLsDraft} onChange={event => setRelayURLsDraft(event.target.value)} aria-label={t("relaySettings")} />
        <button className="mt-2 border border-border px-2 py-1" disabled={savingRelayURLs} onClick={() => void saveRelayURLs()}>{t("saveRelaySettings")}</button>
      </section> : null}
      {directory ? devices.map(device => {
        const manageable = directory.managedDeviceIds.includes(device.deviceRecordId);
        return (
          <section key={device.deviceRecordId} className="border border-border p-3" data-device-id={device.deviceRecordId}>
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 className="font-medium">{device.descriptor.metadata.displayName}</h2>
                <p className="mt-1 text-xs text-muted">{device.descriptor.metadata.platform} · {device.descriptor.metadata.appVersion}</p>
              </div>
              {manageable ? <button className="border border-border px-2 py-1" disabled={busyDevice === device.deviceRecordId} onClick={async () => {
                setBusyDevice(device.deviceRecordId); setError(null);
                try { await controllerRef.current?.revoke(device.deviceRecordId); }
                catch (cause) { setError(cause instanceof Error ? cause.message : t("mutationError")); }
                finally { setBusyDevice(null); }
              }}>{t("revoke")}</button> : null}
            </div>
            <dl className="mt-3 grid gap-2 text-xs sm:grid-cols-3">
              <Fact label={t("deviceId")} value={`…${device.descriptor.identity.deviceId.slice(-8)}`} />
              <Fact label={t("revision")} value={String(device.revision)} />
              <Fact label={t("status")} value={device.revoked ? t("revoked") : t("active")} />
            </dl>
          </section>
        );
      }) : null}
    </div>
  );
}

function Fact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1">{value}</dd></div>;
}
