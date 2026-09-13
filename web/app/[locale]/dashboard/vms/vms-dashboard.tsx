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
type DashboardVm = { readonly id: string; readonly displayName: string | null; readonly slug?: string | null; readonly status: string };
type VmListBody = { readonly vms?: unknown; readonly limits?: { readonly maxActiveVms?: unknown } };

export function VmsDashboard({ userId, userEmail }: Props) {
  const t = useTranslations("dashboard.iroh");
  const stack = useStackApp();
  const teamScope = useDashboardTeamScope(userId);
  const teamId = teamScope.status === "ready" ? teamScope.selected.id : null;
  const [directory, setDirectory] = useState<DashboardDirectory | null>(null);
  const [workspaces, setWorkspaces] = useState<readonly DashboardWorkspace[]>([]);
  const [vms, setVms] = useState<readonly DashboardVm[]>([]);
  const [maxActiveVms, setMaxActiveVms] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
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
      .then(async response => response.ok ? await response.json() as VmListBody : null)
      .then(body => {
        if (!body || !Array.isArray(body.vms)) return;
        setVms(body.vms.filter(isDashboardVm));
        setMaxActiveVms(typeof body.limits?.maxActiveVms === "number" ? body.limits.maxActiveVms : null);
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

  const workspaceByVmId = useMemo(() => new Map(workspaces.map(value => [value.vmId, value])), [workspaces]);
  const knownVmIds = useMemo(() => new Set(vms.map(vm => vm.id)), [vms]);
  const vmRows = useMemo(() => [
    ...vms,
    ...workspaces.filter(value => !knownVmIds.has(value.vmId)).map(value => ({ id: value.vmId, displayName: null, slug: null, status: "connected" } satisfies DashboardVm)),
  ], [vms, knownVmIds, workspaces]);
  return (
    <div className="space-y-4" data-testid="iroh-dashboard">
      {teamScope.status === "loading" ? <p className="text-muted">{t("loading")}</p> : null}
      {teamScope.status === "unavailable" ? <p role="alert" className="border border-red-500/40 p-3 text-sm">{t("unavailable")}</p> : null}
      {error ? <p role="alert" className="border border-red-500/40 p-3 text-sm">{error}</p> : null}
      {!directory && !error ? <p className="text-muted">{t("loading")}</p> : null}
      <section data-testid="connected-workspaces" className="space-y-1">
        <div className="flex items-center justify-between text-sm text-muted">
          <span>{t("machineCount", { count: vmRows.length, max: maxActiveVms ?? "—" })}</span>
        </div>
        {vmRows.length === 0 ? <p className="py-3 text-muted">{t("vmsEmpty")}</p> : vmRows.map(vm => {
          const workspaceVm = workspaceByVmId.get(vm.id);
          return <article key={vm.id} className="border-b border-border py-4 last:border-b-0" data-vm-id={vm.id} data-vm-catalog-id={vm.id}>
            <div className="flex items-center gap-2">
              <CloudIcon />
              <h3 className="font-medium">{vm.slug || vm.displayName || t("vmLabel", { id: `…${vm.id.slice(-8)}` })}</h3>
              <span className="text-xs text-muted">{vm.status}</span>
            </div>
            <div className="mt-3 space-y-3 pl-5">
              <TreeGroupLabel label={t("workspacesGroup")} />
              {workspaceVm?.snapshot.workspaces.map(workspace => {
                    const terminals = workspaceVm.snapshot.terminals.filter(terminal => terminal.workspaceId === workspace.id);
                    return (
                      <div key={workspace.id} className="pl-2">
                        <div className="flex items-center gap-2">
                          <ChevronIcon />
                          <FolderIcon />
                          <span className={workspace.focused ? "font-medium" : ""}>{workspace.name}</span>
                          <span className="text-xs text-muted">{t("terminalCount", { count: terminals.length })}</span>
                        </div>
                        <ul className="ml-7 mt-1 space-y-1 text-xs text-muted">
                          {terminals.map(terminal => <li key={terminal.id} className="flex items-center gap-2"><TerminalIcon /><span>{terminal.title}</span><span className="truncate">{terminal.cwd ?? "~"}</span></li>)}
                        </ul>
                      </div>
                    );
                  })}
              {!workspaceVm ? <div className="pl-2 text-xs text-muted">{t("workspacesEmpty")}</div> : null}
              <TreeGroupLabel label={t("portsGroup")} />
              <div className="pl-2 text-xs text-muted">{t("portsEmpty")}</div>
              <TreeGroupLabel label={t("displaysGroup")} />
              <div className="flex items-center gap-2 pl-2 text-xs text-muted"><DisplayIcon /><span>{t("desktop")}</span><span>noVNC</span></div>
              <TreeGroupLabel label={t("terminalsGroup")} />
              {workspaceVm?.snapshot.terminals.length ? workspaceVm.snapshot.terminals.map(terminal => <div key={`${terminal.id}-pool`} className="flex items-center gap-2 pl-2 text-xs text-muted"><TerminalIcon /><span>{terminal.title}</span></div>) : <div className="pl-2 text-xs text-muted">{t("terminalsEmpty")}</div>}
            </div>
            {workspaceVm ? <div className="mt-3 text-right text-xs text-muted">{t("revisionLabel", { revision: workspaceVm.revision })}</div> : null}
          </article>;
        })}
      </section>
      <span className="sr-only">{userEmail}</span>
    </div>
  );
}

function TreeGroupLabel({ label }: { readonly label: string }) {
  return <div className="text-xs font-medium text-muted">{label}</div>;
}

function isDashboardVm(value: unknown): value is DashboardVm {
  if (!value || typeof value !== "object") return false;
  const candidate = value as DashboardVm;
  return typeof candidate.id === "string" && typeof candidate.status === "string" &&
    (candidate.slug === undefined || candidate.slug === null || typeof candidate.slug === "string");
}

function CloudIcon() {
  return <svg aria-hidden="true" className="size-3.5 shrink-0 text-muted" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round"><path d="M4.5 12.5h7a2.5 2.5 0 0 0 .3-4.98A4 4 0 0 0 4.2 6.2 3.2 3.2 0 0 0 4.5 12.5Z" /></svg>;
}

function ChevronIcon() {
  return <svg aria-hidden="true" className="size-3 shrink-0 text-muted" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round"><path d="m3 4.5 3 3 3-3" /></svg>;
}

function FolderIcon() {
  return <svg aria-hidden="true" className="size-3.5 shrink-0 text-muted" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round"><path d="M1.75 4.5h4l1.25 1.5h7.25v6.75a1.5 1.5 0 0 1-1.5 1.5h-10a1.5 1.5 0 0 1-1.5-1.5V4.5Z" /></svg>;
}

function TerminalIcon() {
  return <svg aria-hidden="true" className="size-3.5 shrink-0 text-muted" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round"><rect x="1.75" y="2.25" width="12.5" height="11.5" rx="1.5" /><path d="m4 6 2 2-2 2M7.5 10h2.5" /></svg>;
}

function DisplayIcon() {
  return <svg aria-hidden="true" className="size-3.5 shrink-0 text-muted" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round"><rect x="1.75" y="2.5" width="12.5" height="8" rx="1.25" /><path d="M5.5 13.5h5M8 10.5v3" /></svg>;
}

function Fact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1">{value}</dd></div>;
}
