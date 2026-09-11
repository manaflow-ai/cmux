"use client";

import { useStackApp, useUser } from "@stackframe/stack";
import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { useRouter } from "@/i18n/navigation";
import {
  persistCoderouterOrganizationScope,
  coderouterOrganizationFromCookieHeader,
} from "@/services/coderouter/organizationScope";
import { V2DashboardController, type DashboardDirectory } from "./v2-dashboard-controller";

const PROJECT_ID = process.env.NEXT_PUBLIC_STACK_PROJECT_ID ?? "";
const DEFAULT_ENVIRONMENT = process.env.NEXT_PUBLIC_IROH_V2_ENVIRONMENT ??
  (process.env.NODE_ENV === "production" ? "production" : "development");
const DEFAULT_ORIGIN = process.env.NEXT_PUBLIC_IROH_V2_ORIGIN ??
  `https://cmux-iroh-v2${DEFAULT_ENVIRONMENT === "production" ? "" : `-${DEFAULT_ENVIRONMENT}`}.cmux-presence-worker.workers.dev`;

type Props = { readonly userId: string; readonly userEmail: string };

export function IrohDashboard({ userId, userEmail }: Props) {
  const t = useTranslations("dashboard.iroh");
  const stack = useStackApp();
  const user = useUser({ or: "return-null" });
  const router = useRouter();
  const [teamId, setTeamId] = useState<string | null>(() => user?.selectedTeam?.id ?? null);
  const [directory, setDirectory] = useState<DashboardDirectory | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyDevice, setBusyDevice] = useState<string | null>(null);
  const [relayURLsDraft, setRelayURLsDraft] = useState("");
  const [savingRelayURLs, setSavingRelayURLs] = useState(false);
  const controllerRef = useRef<V2DashboardController | null>(null);
  const teams = user?.useTeams() ?? [];

  useEffect(() => {
    const cookieTeam = coderouterOrganizationFromCookieHeader(
      typeof document === "undefined" ? null : document.cookie,
      userId,
    );
    setTeamId(cookieTeam ?? user?.selectedTeam?.id ?? teams[0]?.id ?? null);
  }, [userId, user?.selectedTeam?.id, teams]);

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
      onDirectory: next => { if (!cancelled) setDirectory(next); },
      onError: next => { if (!cancelled) setError(next); },
    });
    controllerRef.current = controller;
    setDirectory(null);
    setError(null);
    void controller.start();
    return () => {
      cancelled = true;
      if (controllerRef.current === controller) controllerRef.current = null;
      void controller.stop();
    };
  }, [stack, teamId, userId]);

  const chooseTeam = (next: string) => {
    if (!next || next === teamId) return;
    persistCoderouterOrganizationScope(userId, next);
    setTeamId(next);
    router.refresh();
  };

  const devices = useMemo(() => directory?.devices ?? [], [directory]);
  useEffect(() => {
    if (directory) setRelayURLsDraft(directory.relayURLs.join("\n"));
  }, [directory]);
  const saveRelayURLs = async () => {
    const relayURLs = relayURLsDraft.split(/\s+/u).map(value => value.trim()).filter(Boolean);
    setSavingRelayURLs(true); setError(null);
    try { await controllerRef.current?.updateRelayPreferences(relayURLs); }
    catch (cause) { setError(cause instanceof Error ? cause.message : t("mutationError")); }
    finally { setSavingRelayURLs(false); }
  };
  return (
    <div className="space-y-4" data-testid="iroh-dashboard">
      <label className="block text-xs text-muted" htmlFor="iroh-team">{t("team")}</label>
      <select id="iroh-team" value={teamId ?? ""} onChange={event => chooseTeam(event.target.value)} className="border border-border bg-background px-2 py-1.5">
        {teams.map(team => <option key={team.id} value={team.id}>{team.displayName}</option>)}
      </select>
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
        const manageable = directory.managedDeviceIds.includes(device.deviceRecordId) && directory.canManageTeam;
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
      <span className="sr-only">{userEmail}</span>
    </div>
  );
}

function Fact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1">{value}</dd></div>;
}
