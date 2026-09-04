import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { listVmAccessGrants, runVmWorkflow } from "@/services/vms/workflows";
import { CloudDeviceActions } from "./device-actions";

export default async function CloudDevicesPage({
  params,
}: {
  readonly params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect("/");
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/cloud")));
  const [t, devices] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.cloud" }),
    runVmWorkflow(listVmAccessGrants({ userId: user.id })),
  ]);
  const dates = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" });

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {devices.length === 0 ? (
        <p className="border border-border p-3 text-muted">{t("empty")}</p>
      ) : (
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
      )}
    </div>
  );
}

function DeviceFact({ label, value }: { readonly label: string; readonly value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1 break-words text-foreground">{value}</dd></div>;
}
