"use client";

import {
  Outlet,
  RouterProvider,
  createRootRoute,
  createRoute,
  createRouter,
  createMemoryHistory,
  useNavigate,
  useRouterState,
} from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Tabs } from "@base-ui-components/react/tabs";
import { useLocale, useTranslations } from "next-intl";
import { createContext, useContext, useState, useSyncExternalStore } from "react";

import {
  createCloudMachine,
  deleteCloudMachine,
  listCloudMachines,
  listCloudSessions,
  shortMachineId,
  type CloudMachine,
} from "./cloud-api";

const machinesQueryKey = ["cloud-portal", "machines"] as const;
const PortalIdentityContext = createContext("");
const subscribeToClientMount = () => () => undefined;

const rootRoute = createRootRoute({ component: PortalFrame });
const machinesRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: MachinesView,
});
const activityRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/activity",
  component: ActivityView,
});
const machineRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/machines/$machineId",
  component: MachineView,
});
const routeTree = rootRoute.addChildren([machinesRoute, activityRoute, machineRoute]);

function createCloudPortalRouter(initialPath = "/") {
  return createRouter({
    routeTree,
    history: createMemoryHistory({ initialEntries: [initialPath] }),
    defaultPreload: "intent",
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof createCloudPortalRouter>;
  }
}

export function CloudPortal({ displayName, initialPath = "/" }: { displayName: string; initialPath?: string }) {
  const [router] = useState(() => createCloudPortalRouter(initialPath));
  const isClient = useSyncExternalStore(subscribeToClientMount, () => true, () => false);
  return (
    <PortalIdentityContext.Provider value={displayName}>
      <div className="h-full min-h-[calc(100vh-3.25rem)]">
        {isClient ? <RouterProvider router={router} /> : <PortalLoading />}
      </div>
    </PortalIdentityContext.Provider>
  );
}

function PortalLoading() {
  return (
    <div aria-hidden="true" className="p-4 md:p-6">
      <div className="h-14 animate-pulse rounded-xl bg-code-bg" />
      <div className="mt-5 grid gap-3 lg:grid-cols-2">
        <div className="h-32 animate-pulse rounded-xl bg-code-bg" />
        <div className="h-32 animate-pulse rounded-xl bg-code-bg" />
      </div>
    </div>
  );
}

function PortalFrame() {
  const t = useTranslations("dashboard.cloud");
  const navigate = useNavigate();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const machinesActive = pathname !== "/activity";
  const activeView = machinesActive ? "machines" : "activity";
  return (
    <Tabs.Root
      value={activeView}
      onValueChange={(value) => navigate({ to: value === "activity" ? "/activity" : "/" })}
      className="flex h-full min-h-[calc(100vh-3.25rem)] flex-col bg-background"
    >
      <div className="flex min-h-14 flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-2.5 md:px-6">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-[0.16em] text-muted">
            {t("eyebrow")}
          </p>
          <h1 className="text-base font-semibold tracking-tight">{t("title")}</h1>
        </div>
        <Tabs.List activateOnFocus aria-label={t("viewNavigationLabel")} className="flex rounded-lg bg-code-bg p-1">
          <Tabs.Tab value="machines" className="rounded-md px-3 py-1.5 text-xs font-medium text-muted transition-colors hover:text-foreground focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground data-[selected]:bg-background data-[selected]:text-foreground data-[selected]:shadow-sm">
            {t("machinesTab")}
          </Tabs.Tab>
          <Tabs.Tab value="activity" className="rounded-md px-3 py-1.5 text-xs font-medium text-muted transition-colors hover:text-foreground focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground data-[selected]:bg-background data-[selected]:text-foreground data-[selected]:shadow-sm">
            {t("activityTab")}
          </Tabs.Tab>
        </Tabs.List>
      </div>
      <Tabs.Panel value="machines" keepMounted className="min-h-0 flex-1">
        {machinesActive ? <Outlet /> : null}
      </Tabs.Panel>
      <Tabs.Panel value="activity" keepMounted className="min-h-0 flex-1">
        {!machinesActive ? <Outlet /> : null}
      </Tabs.Panel>
    </Tabs.Root>
  );
}

function MachinesView() {
  const t = useTranslations("dashboard.cloud");
  const displayName = useContext(PortalIdentityContext);
  const queryClient = useQueryClient();
  const machines = useQuery({
    queryKey: machinesQueryKey,
    queryFn: listCloudMachines,
    refetchInterval: (query) => query.state.data?.some((machine) => machine.status === "provisioning") ? 3_000 : false,
  });
  const createMachine = useMutation({
    mutationFn: createCloudMachine,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: machinesQueryKey });
    },
  });

  return (
    <div className="mx-auto w-full max-w-6xl p-4 md:p-6">
      <section className="mb-5 flex flex-col gap-4 rounded-xl border border-border bg-code-bg/45 p-5 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-lg font-semibold tracking-tight">{t("welcomeTitle", { name: displayName })}</h2>
          <p className="mt-1 max-w-2xl text-sm leading-6 text-muted">{t("welcomeBody")}</p>
        </div>
        <button
          type="button"
          disabled={createMachine.isPending}
          onClick={() => createMachine.mutate()}
          className="inline-flex min-h-10 shrink-0 items-center justify-center rounded-lg bg-foreground px-4 text-sm font-semibold text-background transition-opacity hover:opacity-85 disabled:cursor-wait disabled:opacity-55 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground"
        >
          <span aria-hidden="true" className="mr-2 text-base">＋</span>
          {createMachine.isPending ? t("creatingMachine") : t("newMachine")}
        </button>
      </section>

      {createMachine.isError ? <PortalError message={t("createError")} /> : null}
      {machines.isPending ? <MachineGridSkeleton /> : null}
      {machines.isError ? (
        <PortalError message={t("loadError")} retry={() => machines.refetch()} />
      ) : null}
      {machines.data?.length === 0 ? <EmptyMachines /> : null}
      {machines.data?.length ? (
        <div className="grid gap-3 lg:grid-cols-2">
          {machines.data.map((machine) => <MachineCard key={machine.id} machine={machine} />)}
        </div>
      ) : null}
    </div>
  );
}

function MachineCard({ machine }: { machine: CloudMachine }) {
  const t = useTranslations("dashboard.cloud");
  const locale = useLocale();
  const navigate = useNavigate();
  return (
    <button
      type="button"
      onClick={() => navigate({ to: "/machines/$machineId", params: { machineId: machine.id } })}
      className="group rounded-xl border border-border bg-background p-4 text-left transition-colors hover:bg-code-bg/55 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-3">
          <span className="grid size-10 shrink-0 place-items-center rounded-lg border border-border bg-code-bg font-mono text-xs font-semibold">
            cm
          </span>
          <div className="min-w-0">
            <h3 className="truncate font-mono text-sm font-semibold">{shortMachineId(machine.id)}</h3>
            <p className="mt-0.5 truncate text-xs text-muted">{machine.image || t("defaultImage")}</p>
          </div>
        </div>
        <StatusPill status={machine.status} />
      </div>
      <div className="mt-4 flex items-center justify-between border-t border-border pt-3 text-xs text-muted">
        <span>{t("created", { date: formatDate(machine.createdAt, locale) })}</span>
        <span className="font-medium text-foreground opacity-70 transition-opacity group-hover:opacity-100">
          {t("openMachine")} →
        </span>
      </div>
    </button>
  );
}

function MachineView() {
  const t = useTranslations("dashboard.cloud");
  const sessionStatus = useTranslations("dashboard.cloud.sessionStatus");
  const locale = useLocale();
  const queryClient = useQueryClient();
  const { machineId } = machineRoute.useParams();
  const navigate = useNavigate();
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const machines = useQuery({ queryKey: machinesQueryKey, queryFn: listCloudMachines });
  const sessions = useQuery({
    queryKey: ["cloud-portal", "sessions", machineId],
    queryFn: () => listCloudSessions(machineId),
  });
  const removeMachine = useMutation({
    mutationFn: () => deleteCloudMachine(machineId),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: machinesQueryKey });
      await navigate({ to: "/" });
    },
  });
  const machine = machines.data?.find((entry) => entry.id === machineId);

  return (
    <div className="mx-auto w-full max-w-6xl p-4 md:p-6">
      <button type="button" onClick={() => navigate({ to: "/" })} className="text-xs font-medium text-muted hover:text-foreground">
        ← {t("backToMachines")}
      </button>
      <div className="mt-4 flex flex-col gap-4 border-b border-border pb-5 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <h2 className="truncate font-mono text-lg font-semibold">{shortMachineId(machineId)}</h2>
            {machine ? <StatusPill status={machine.status} /> : null}
          </div>
          <p className="mt-1 text-sm text-muted">
            {machine ? t("machineSummary", { image: machine.image || t("defaultImage") }) : t("loadingMachine")}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {confirmingDelete ? (
            <>
              <button type="button" onClick={() => setConfirmingDelete(false)} className="rounded-lg border border-border px-3 py-2 text-xs font-medium hover:bg-code-bg">
                {t("cancel")}
              </button>
              <button type="button" disabled={removeMachine.isPending} onClick={() => removeMachine.mutate()} className="rounded-lg bg-red-600 px-3 py-2 text-xs font-semibold text-white hover:bg-red-700 disabled:opacity-55">
                {removeMachine.isPending ? t("deletingMachine") : t("confirmDelete")}
              </button>
            </>
          ) : (
            <button type="button" onClick={() => setConfirmingDelete(true)} className="rounded-lg border border-border px-3 py-2 text-xs font-medium text-muted hover:border-red-500 hover:text-red-600">
              {t("deleteMachine")}
            </button>
          )}
        </div>
      </div>

      {removeMachine.isError ? <div className="mt-4"><PortalError message={t("deleteError")} /></div> : null}

      <section className="mt-6">
        <div className="mb-3 flex items-end justify-between">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[0.16em] text-muted">{t("sessionsEyebrow")}</p>
            <h3 className="mt-1 font-semibold">{t("sessionsTitle")}</h3>
          </div>
          <button type="button" onClick={() => sessions.refetch()} className="text-xs font-medium text-muted hover:text-foreground">
            {t("refresh")}
          </button>
        </div>
        {sessions.isPending ? <MachineGridSkeleton /> : null}
        {sessions.isError ? <PortalError message={t("sessionsError")} retry={() => sessions.refetch()} /> : null}
        {sessions.data?.length === 0 ? (
          <div className="rounded-xl border border-dashed border-border p-8 text-center">
            <p className="text-sm font-medium">{t("noSessionsTitle")}</p>
            <p className="mt-1 text-xs text-muted">{t("noSessionsBody")}</p>
          </div>
        ) : null}
        <div className="space-y-2">
          {sessions.data?.map((session) => (
            <article key={session.id} className="flex items-center gap-3 rounded-xl border border-border p-3">
              <span
                aria-hidden="true"
                className={`size-2 rounded-full ${sessionStatusDotClass(session.status)}`}
              />
              <div className="min-w-0 flex-1">
                <h4 className="truncate text-sm font-medium">{session.title || t("untitledSession")}</h4>
                <p className="mt-0.5 text-xs text-muted">{t("sessionUpdated", { date: formatDate(session.updatedAt, locale) })}</p>
              </div>
              <span className="rounded-md bg-code-bg px-2 py-1 text-[11px] font-medium text-muted">{sessionStatus(session.status)}</span>
            </article>
          ))}
        </div>
      </section>
    </div>
  );
}

function ActivityView() {
  const t = useTranslations("dashboard.cloud");
  const locale = useLocale();
  const machines = useQuery({ queryKey: machinesQueryKey, queryFn: listCloudMachines });
  const orderedMachines = [...(machines.data ?? [])].sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
  return (
    <div className="mx-auto w-full max-w-4xl p-4 md:p-6">
      <div className="mb-5">
        <h2 className="text-lg font-semibold">{t("activityTitle")}</h2>
        <p className="mt-1 text-sm text-muted">{t("activityBody")}</p>
      </div>
      {machines.isPending ? <MachineGridSkeleton /> : null}
      {machines.isError ? <PortalError message={t("loadError")} retry={() => machines.refetch()} /> : null}
      {orderedMachines.length === 0 && !machines.isPending ? <EmptyMachines /> : null}
      <ol className="relative ml-2 border-l border-border">
        {orderedMachines.map((machine) => (
          <li key={machine.id} className="relative pb-6 pl-6 last:pb-0">
            <span className="absolute -left-1.5 top-1 size-3 rounded-full border-2 border-background bg-emerald-500" />
            <p className="text-sm font-medium">{t("machineCreated", { id: shortMachineId(machine.id) })}</p>
            <p className="mt-1 text-xs text-muted">{formatDate(machine.createdAt, locale)}</p>
          </li>
        ))}
      </ol>
    </div>
  );
}

function StatusPill({ status }: { status: CloudMachine["status"] }) {
  const t = useTranslations("dashboard.cloud.status");
  const tone = status === "running"
    ? "bg-emerald-500/12 text-emerald-700 dark:text-emerald-400"
    : status === "failed"
      ? "bg-red-500/12 text-red-700 dark:text-red-400"
      : "bg-amber-500/12 text-amber-700 dark:text-amber-400";
  return <span className={`rounded-full px-2 py-1 text-[11px] font-semibold ${tone}`}>{t(status)}</span>;
}

function sessionStatusDotClass(status: "running" | "detached" | "exited" | "closed"): string {
  if (status === "running") return "bg-emerald-500";
  if (status === "detached") return "bg-amber-500";
  return "bg-muted";
}

function EmptyMachines() {
  const t = useTranslations("dashboard.cloud");
  return (
    <div className="rounded-xl border border-dashed border-border px-6 py-12 text-center">
      <div aria-hidden="true" className="mx-auto grid size-12 place-items-center rounded-xl bg-code-bg font-mono text-sm">$</div>
      <h3 className="mt-4 font-semibold">{t("emptyTitle")}</h3>
      <p className="mx-auto mt-1 max-w-md text-sm text-muted">{t("emptyBody")}</p>
    </div>
  );
}

function PortalError({ message, retry }: { message: string; retry?: () => unknown }) {
  const t = useTranslations("dashboard.cloud");
  return (
    <div role="alert" className="mb-4 flex items-center justify-between gap-3 rounded-lg border border-red-500/35 bg-red-500/8 px-4 py-3 text-sm text-red-700 dark:text-red-300">
      <span>{message}</span>
      {retry ? <button type="button" onClick={retry} className="font-semibold underline underline-offset-2">{t("retry")}</button> : null}
    </div>
  );
}

function MachineGridSkeleton() {
  return (
    <div aria-hidden="true" className="grid gap-3 lg:grid-cols-2">
      {[0, 1].map((index) => <div key={index} className="h-32 animate-pulse rounded-xl bg-code-bg" />)}
    </div>
  );
}

function formatDate(value: string, locale: string): string {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return value;
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(timestamp);
}
