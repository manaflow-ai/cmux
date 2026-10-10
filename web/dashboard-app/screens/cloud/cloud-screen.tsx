"use client";

import { useQuery, useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { DashboardSectionSkeleton } from "../../components/dashboard-skeleton";
import { EmptyState, SectionError } from "../../components/page-states";
import { cloudDevicesQuery, cloudMachinesQuery, type CloudDevice, type CloudMachine } from "../../queries/cloud";
import { CloudPageFrame } from "./cloud-frame";
import { CloudDeviceActions } from "./device-actions";
import { MachineNetworkControl } from "./network-policy-editor";

export function CloudScreen() {
  const t = useTranslations("dashboard.cloud");
  const { data: devices } = useSuspenseQuery(cloudDevicesQuery);
  return (
    <CloudPageFrame>
      <h2 className="mb-2 text-xs font-medium text-muted">{t("machines.title")}</h2>
      <CloudMachinesRegion />
      <h2 className="mb-2 mt-6 text-xs font-medium text-muted">{t("macAccessTitle")}</h2>
      <CloudDevicesSection devices={devices} />
    </CloudPageFrame>
  );
}

/**
 * Machines load beside the Mac list, not in the route loader, so a failing
 * machine list never hides Mac access (and the reverse).
 */
function CloudMachinesRegion() {
  const t = useTranslations("dashboard.cloud.machines");
  const query = useQuery(cloudMachinesQuery);
  if (query.isPending) return <DashboardSectionSkeleton variant="list" rows={2} />;
  if (query.isError) return <SectionError error={query.error} section={t("title")} onRetry={() => query.refetch()} />;
  return <CloudMachinesSection machines={query.data} />;
}

export function CloudMachinesSection({ machines }: { readonly machines: readonly CloudMachine[] }) {
  const t = useTranslations("dashboard.cloud.machines");
  if (machines.length === 0) {
    return <p className="border border-border p-3 text-muted">{t("empty")}</p>;
  }
  return (
    <div className="divide-y divide-border border border-border">
      {machines.map((machine) => (
        <div key={machine.id} className="flex flex-wrap items-center justify-between gap-3 p-3">
          <div className="min-w-0">
            <p className="truncate font-medium">{machine.name}</p>
            <p className="mt-1 text-xs text-muted">
              {[t(machine.teamId ? "team" : "personal"), t(`status.${machine.status}`), machine.id].join(" · ")}
            </p>
          </div>
          <MachineNetworkControl vmId={machine.id} teamId={machine.teamId} name={machine.name} />
        </div>
      ))}
    </div>
  );
}

export function CloudDevicesSection({ devices }: { readonly devices: readonly CloudDevice[] }) {
  const t = useTranslations("dashboard.cloud");
  const locale = useLocale();
  const dates = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" });

  if (devices.length === 0) {
    return <EmptyState title={t("empty")} body={t("emptyBody")} />;
  }
  return (
    <div className="space-y-3">
      {devices.map((device) => (
        <section key={device.id} className="border border-border p-3">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="font-medium">{device.name}</h2>
              <p className="mt-1 text-xs text-muted">
                {[device.modelIdentifier, device.osVersion && `macOS ${device.osVersion}`, device.architecture]
                  .filter(Boolean).join(" · ")}
              </p>
            </div>
            <CloudDeviceActions id={device.id} name={device.name} />
          </div>
          <dl className="mt-4 grid gap-3 text-xs sm:grid-cols-2 lg:grid-cols-4">
            <DeviceFact label={t("cmux")} value={[device.cmuxChannel, device.cmuxVersion, device.cmuxBuild && `(${device.cmuxBuild})`].filter(Boolean).join(" ") || t("unknown")} />
            <DeviceFact label={t("access")} value={device.tunnelPurposes.length ? device.tunnelPurposes.map((purpose) => t(`purpose.${purpose}`)).join(", ") : t("none")} />
            <DeviceFact label={t("lastContact")} value={dates.format(new Date(device.lastControlPlaneAt))} />
            <DeviceFact label={t("deviceId")} value={`…${device.deviceId.slice(-8)}`} />
          </dl>
        </section>
      ))}
    </div>
  );
}

function DeviceFact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1 break-words text-foreground">{value}</dd></div>;
}
