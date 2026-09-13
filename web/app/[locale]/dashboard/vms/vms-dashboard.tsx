"use client";

import { useStackApp } from "@stackframe/stack";
import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { useDashboardTeamScope } from "../dashboard-team-scope";
import { V2DashboardController, type DashboardDirectory, type DashboardWorkspace } from "./v2-dashboard-controller";

const PROJECT_ID = process.env.NEXT_PUBLIC_STACK_PROJECT_ID ?? "";
const DEFAULT_ENVIRONMENT = process.env.NEXT_PUBLIC_IROH_V2_ENVIRONMENT ??
  (process.env.NODE_ENV === "production" ? "production" : "development");
const DEFAULT_WORKERS_SUBDOMAIN = process.env.NEXT_PUBLIC_IROH_V2_WORKERS_SUBDOMAIN ??
  (DEFAULT_ENVIRONMENT === "development" ? "debussy" : "cmux-presence-worker");
const DEFAULT_ORIGIN = process.env.NEXT_PUBLIC_IROH_V2_ORIGIN ??
  `https://cmux-iroh-v2${DEFAULT_ENVIRONMENT === "production" ? "" : `-${DEFAULT_ENVIRONMENT}`}.${DEFAULT_WORKERS_SUBDOMAIN}.workers.dev`;

type Props = { readonly userId: string; readonly userEmail: string };
type DashboardVm = { readonly id: string; readonly displayName: string | null; readonly status: string };

export function VmsDashboard({ userId, userEmail }: Props) {
  const t = useTranslations("dashboard.iroh");
  const stack = useStackApp();
  const teamScope = useDashboardTeamScope(userId);
  const teamId = teamScope.status === "ready" ? teamScope.selected.id : null;
  const [directory, setDirectory] = useState<DashboardDirectory | null>(null);
  const [workspaces, setWorkspaces] = useState<readonly DashboardWorkspace[]>([]);
  const [vms, setVms] = useState<readonly DashboardVm[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busyDevice, setBusyDevice] = useState<string | null>(null);
  const [relayURLsDraft, setRelayURLsDraft] = useState("");
  const [savingRelayURLs, setSavingRelayURLs] = useState(false);
  const redirectingToSignInRef = useRef(false);
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
      onDirectory: next => { if (!cancelled) setDirectory(next); },
      onWorkspaces: next => { if (!cancelled) setWorkspaces(next); },
      onAuthExpired: () => {
        if (cancelled || redirectingToSignInRef.current) return;
        redirectingToSignInRef.current = true;
        void stack.redirectToSignIn({ replace: true });
      },
      onError: next => { if (!cancelled) setError(next); },
    });
    controllerRef.current = controller;
    setDirectory(null);
    setWorkspaces([]);
    setVms([]);
    void fetch(`/api/vm?teamId=${encodeURIComponent(teamId)}`, { credentials: "include", headers: { accept: "application/json" } })
      .then(async response => response.ok ? await response.json() as { vms?: unknown } : null)
      .then(body => {
        if (!body || !Array.isArray(body.vms)) return;
        setVms(body.vms.filter((value): value is DashboardVm => !!value && typeof value === "object" && typeof (value as DashboardVm).id === "string" && typeof (value as DashboardVm).status === "string"));
      })
      .catch(() => undefined);
    setError(null);
    void controller.start();
    return () => {
      cancelled = true;
      if (controllerRef.current === controller) controllerRef.current = null;
      void controller.stop();
    };
  }, [stack, teamId, userId]);

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
      {teamScope.status === "loading" ? <p className="text-muted">{t("loading")}</p> : null}
      {teamScope.status === "unavailable" ? <p role="alert" className="border border-red-500/40 p-3 text-sm">{t("unavailable")}</p> : null}
      {error ? <p role="alert" className="border border-red-500/40 p-3 text-sm">{error}</p> : null}
      {!directory && !error ? <p className="text-muted">{t("loading")}</p> : null}
      {directory && devices.length === 0 ? <p className="border border-border p-3 text-muted">{t("empty")}</p> : null}
      {directory?.canManageTeam ? <section className="border border-border p-3" data-testid="iroh-relay-settings">
        <h2 className="font-medium">{t("relaySettings")}</h2>
        <p className="mt-1 text-xs text-muted">{t("relaySettingsDescription")}</p>
        <textarea className="mt-3 min-h-20 w-full border border-border bg-background p-2 font-mono text-xs" value={relayURLsDraft} onChange={event => setRelayURLsDraft(event.target.value)} aria-label={t("relaySettings")} />
        <button className="mt-2 border border-border px-2 py-1" disabled={savingRelayURLs} onClick={() => void saveRelayURLs()}>{t("saveRelaySettings")}</button>
      </section> : null}
      <section className="border border-border p-3" data-testid="connected-workspaces">
        <h2 className="font-medium">{t("vmsTitle")}</h2>
        <p className="mt-1 text-xs text-muted">{t("vmsDescription")}</p>
        {vms.length === 0 ? <p className="mt-3 text-muted">{t("vmsEmpty")}</p> : (
          <div className="mt-3 grid gap-2 sm:grid-cols-2">
            {vms.map(vm => <div key={vm.id} className="border border-border p-2" data-vm-catalog-id={vm.id}>
              <div className="font-medium">{vm.displayName || t("unnamedVm")}</div>
              <div className="mt-1 text-xs text-muted">{vm.status} · …{vm.id.slice(-8)}</div>
            </div>)}
          </div>
        )}
        <h2 className="mt-5 font-medium">{t("workspacesTitle")}</h2>
        <p className="mt-1 text-xs text-muted">{t("workspacesDescription")}</p>
        {workspaces.length === 0 ? <p className="mt-3 text-muted">{t("workspacesEmpty")}</p> : (
          <div className="mt-3 space-y-3">
            {workspaces.map(vm => (
              <article key={vm.vmId} className="border border-border p-3" data-vm-id={vm.vmId}>
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <h3 className="font-medium">{t("vmLabel", { id: `…${vm.vmId.slice(-8)}` })}</h3>
                  <span className="text-xs text-muted">{t("revisionLabel", { revision: vm.revision })}</span>
                </div>
                <div className="mt-3 space-y-2">
                  {vm.snapshot.workspaces.map(workspace => {
                    const terminals = vm.snapshot.terminals.filter(terminal => terminal.workspaceId === workspace.id);
                    return (
                      <div key={workspace.id} className="border-l border-border pl-3">
                        <div className="flex items-center gap-2">
                          <span className="font-medium">{workspace.name}</span>
                          {workspace.focused ? <span className="text-xs text-muted">{t("focused")}</span> : null}
                        </div>
                        {terminals.length ? <ul className="mt-1 list-disc pl-4 text-xs text-muted">{terminals.map(terminal => <li key={terminal.id}>{terminal.title}</li>)}</ul> : <p className="mt-1 text-xs text-muted">{t("noTerminals")}</p>}
                      </div>
                    );
                  })}
                </div>
              </article>
            ))}
          </div>
        )}
      </section>
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
