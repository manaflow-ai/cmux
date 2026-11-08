import { useT } from "./i18n";

export type AcpmuxDependencyPackage = {
  ecosystem: string;
  name: string;
  status: "ok" | "unavailable";
  version?: string;
  ageDays?: number;
  weeklyDownloads?: number;
  maintainers: number;
  installScripts: boolean;
  lookalike?: string;
};

export type AcpmuxDependency = {
  status: "ok" | "unavailable";
  packages: AcpmuxDependencyPackage[];
};

const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

export function dependencyFromValue(value: unknown): AcpmuxDependency | undefined {
  const raw = record(value);
  if (!raw || !Array.isArray(raw.packages)) return undefined;
  const packages = raw.packages.flatMap((value): AcpmuxDependencyPackage[] => {
    const item = record(value);
    if (!item || typeof item.ecosystem !== "string" || typeof item.name !== "string") return [];
    return [{
      ecosystem: item.ecosystem,
      name: item.name,
      status: item.status === "ok" ? "ok" : "unavailable",
      ...(typeof item.version === "string" ? { version: item.version } : {}),
      ...(typeof item.ageDays === "number" ? { ageDays: item.ageDays } : {}),
      ...(typeof item.weeklyDownloads === "number" ? { weeklyDownloads: item.weeklyDownloads } : {}),
      maintainers: typeof item.maintainers === "number" ? item.maintainers : 0,
      installScripts: item.installScripts === true,
      ...(typeof item.lookalike === "string" ? { lookalike: item.lookalike } : {}),
    }];
  });
  return packages.length ? { status: raw.status === "ok" ? "ok" : "unavailable", packages } : undefined;
}

export function DependencyGate({ dependency, compact = false }: { dependency: AcpmuxDependency; compact?: boolean }) {
  const t = useT();
  return (
    <div className={`acpmux-dependency-gate${compact ? " is-compact" : ""}`} data-dependency-status={dependency.status}>
      <div className="acpmux-dependency-heading">
        <strong>{t("permission.dependencyTitle")}</strong>
        {dependency.status !== "ok" && <span>{t("permission.dependencyUnavailable")}</span>}
      </div>
      <div className="acpmux-dependency-packages">
        {dependency.packages.map((item) => (
          <div className="acpmux-dependency-package" key={`${item.ecosystem}:${item.name}`}>
            <code>{item.name}</code>
            <span className="acpmux-dependency-facts">
              {item.version && <span>{item.version}</span>}
              {item.ageDays !== undefined && <span>{t("permission.dependencyAge", { n: item.ageDays })}</span>}
              {item.weeklyDownloads !== undefined && <span>{t("permission.dependencyDownloads", { n: item.weeklyDownloads.toLocaleString() })}</span>}
              <span>{t("permission.dependencyMaintainers", { n: item.maintainers })}</span>
              {item.installScripts && <span className="is-warning">{t("permission.dependencyScripts")}</span>}
              {item.lookalike && <span className="is-warning">{t("permission.dependencyLookalike", { name: item.lookalike })}</span>}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
