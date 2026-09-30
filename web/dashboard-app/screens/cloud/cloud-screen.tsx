"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { cloudDevicesQuery, type CloudDevice } from "../../queries/cloud";
import { CloudPageFrame } from "./cloud-frame";
import { CloudDeviceActions } from "./device-actions";

export function CloudScreen() {
  const { data: devices } = useSuspenseQuery(cloudDevicesQuery);
  return (
    <CloudPageFrame>
      <CloudDevicesSection devices={devices} />
    </CloudPageFrame>
  );
}

export function CloudDevicesSection({ devices }: { readonly devices: readonly CloudDevice[] }) {
  const t = useTranslations("dashboard.cloud");
  const locale = useLocale();
  const dates = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" });

  if (devices.length === 0) {
    return <p className="border border-border p-3 text-muted">{t("empty")}</p>;
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
