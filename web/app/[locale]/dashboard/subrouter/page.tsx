import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { buildAlternates } from "@/i18n/seo";
import { Link } from "@/i18n/navigation";
import { cloudDb } from "@/db/client";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  type SubrouterAccount,
} from "@/services/subrouter/client";
import { getTenantForTeam } from "@/services/subrouter/tenants";
import {
  AddAiAccountForms,
  DeleteAiAccountButton,
} from "../components/ai-account-forms";

export const dynamic = "force-dynamic";

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
};

type StackUserLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

type DashboardTeam = {
  readonly id: string;
  readonly name: string;
};

type AccountState =
  | { readonly kind: "ok"; readonly accounts: readonly SubrouterAccount[] }
  | { readonly kind: "notConfigured" }
  | { readonly kind: "error" };

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.aiAccounts" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/dashboard/subrouter"),
  };
}

export default async function SubrouterOverviewPage({ params, searchParams }: PageProps) {
  const [{ locale }, { team: teamParam }] = await Promise.all([params, searchParams]);
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const stackUser = (await getStackServerApp().getUser({ or: "return-null" })) as StackUserLike | null;
  if (!stackUser) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/subrouter")));
  }

  const [tPage, t] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.subrouter" }),
    getTranslations({ locale, namespace: "dashboard.aiAccounts" }),
  ]);
  const teams = await dashboardTeams(stackUser, t("personalTeam"));
  const selectedTeam = selectTeam(teams, team);
  const accountState = await loadAccounts(selectedTeam);
  const dateFormatter = new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  });

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{tPage("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{tPage("description")}</p>
      </div>

      <section className="mb-4 border border-border p-3">
        <div className="mb-2 text-xs text-muted">{t("teamSwitcherLabel")}</div>
        <div className="flex flex-wrap gap-3">
          {teams.map((candidate) => {
            const selected = candidate.id === selectedTeam.id;
            return (
              <Link
                key={candidate.id}
                href={`/dashboard/subrouter?team=${encodeURIComponent(candidate.id)}`}
                className={`py-0.5 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
                  selected ? "text-foreground" : "text-muted hover:text-foreground"
                }`}
              >
                {candidate.name}
              </Link>
            );
          })}
        </div>
      </section>

      {accountState.kind === "notConfigured" ? (
        <StatusPanel title={t("notConfiguredTitle")} body={t("notConfiguredBody")} />
      ) : accountState.kind === "error" ? (
        <StatusPanel title={t("loadErrorTitle")} body={t("loadErrorBody")} />
      ) : (
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
          <section>
            <div className="mb-2">
              <h2 className="text-sm font-medium">{t("accountsTitle")}</h2>
              <p className="mt-1 text-xs text-muted">
                {t("accountsCount", { count: accountState.accounts.length })}
              </p>
            </div>

            {accountState.accounts.length === 0 ? (
              <div className="border border-border p-3">
                <div className="text-sm font-medium">{t("emptyTitle")}</div>
                <p className="mt-1 text-xs text-muted">{t("emptyBody")}</p>
              </div>
            ) : (
              <div className="border border-border">
                <div className="hidden grid-cols-[1.2fr_1fr_1fr_auto] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
                  <div>{t("providerColumn")}</div>
                  <div>{t("labelColumn")}</div>
                  <div>{t("createdColumn")}</div>
                  <div className="text-right">{t("actionsColumn")}</div>
                </div>
                {accountState.accounts.map((account) => (
                  <div
                    key={account.id}
                    className="grid gap-2 border-b border-border px-3 py-2 text-sm last:border-b-0 md:grid-cols-[1.2fr_1fr_1fr_auto] md:items-center md:gap-3"
                  >
                    <div>
                      <div className="mb-1 text-xs text-muted md:hidden">
                        {t("providerColumn")}
                      </div>
                      <div>{providerLabel(account.kind, t)}</div>
                    </div>
                    <div className="min-w-0 truncate text-muted">
                      <div className="mb-1 text-xs text-muted md:hidden">
                        {t("labelColumn")}
                      </div>
                      {account.label || t("unlabeledAccount")}
                    </div>
                    <div className="font-mono text-xs text-muted">
                      <div className="mb-1 font-sans text-xs text-muted md:hidden">
                        {t("createdColumn")}
                      </div>
                      {formatCreatedAt(account.createdAt, dateFormatter, t("unknownCreatedAt"))}
                    </div>
                    <DeleteAiAccountButton teamId={selectedTeam.id} accountId={account.id} />
                  </div>
                ))}
              </div>
            )}
          </section>

          <aside>
            <h2 className="mb-2 text-sm font-medium">{t("addAccountsTitle")}</h2>
            <AddAiAccountForms teamId={selectedTeam.id} />
          </aside>
        </div>
      )}
    </div>
  );
}

function StatusPanel({ title, body }: { title: string; body: string }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{title}</h2>
      <p className="mt-1 max-w-2xl text-xs text-muted">{body}</p>
    </section>
  );
}

async function dashboardTeams(user: StackUserLike, personalLabel: string): Promise<readonly DashboardTeam[]> {
  const selectedTeam = teamFromUnknown(user.selectedTeam);
  let listedTeams: readonly (DashboardTeam | null)[] = [];
  if (typeof user.listTeams === "function") {
    try {
      listedTeams = (await user.listTeams()).map(teamFromUnknown);
    } catch {
      // Degrade to the selected/personal team when team listing fails,
      // mirroring how loadAccounts degrades instead of crashing the page.
      listedTeams = [];
    }
  }
  const teams = uniqueTeams([selectedTeam, ...listedTeams]);
  if (teams.length > 0) return teams;
  return [{
    id: user.id,
    name: user.displayName ?? user.primaryEmail ?? personalLabel,
  }];
}

function teamFromUnknown(value: unknown): DashboardTeam | null {
  if (!value || typeof value !== "object") return null;
  const record = value as { id?: unknown; displayName?: unknown; name?: unknown };
  if (typeof record.id !== "string" || !record.id.trim()) return null;
  const rawName = record.displayName ?? record.name;
  return {
    id: record.id,
    name: typeof rawName === "string" && rawName.trim() ? rawName.trim() : record.id,
  };
}

function uniqueTeams(values: readonly (DashboardTeam | null)[]): readonly DashboardTeam[] {
  const teams: DashboardTeam[] = [];
  const seen = new Set<string>();
  for (const team of values) {
    if (!team || seen.has(team.id)) continue;
    seen.add(team.id);
    teams.push(team);
  }
  return teams;
}

function selectTeam(teams: readonly DashboardTeam[], requestedTeamId: string | undefined): DashboardTeam {
  const requested = requestedTeamId?.trim();
  if (requested) {
    const selected = teams.find((team) => team.id === requested);
    if (selected) return selected;
  }
  return teams[0];
}

async function loadAccounts(team: DashboardTeam): Promise<AccountState> {
  const config = subrouterRuntimeConfig();
  if (!config) return { kind: "notConfigured" };

  try {
    const client = createSubrouterClient({
      baseUrl: config.baseUrl,
      adminToken: config.adminToken,
    });
    const tenant = await getTenantForTeam(cloudDb(), team.id, {
      tenantKeySecret: config.tenantKeySecret,
    });
    if (!tenant) return { kind: "ok", accounts: [] };
    const accounts = await client.listAccounts(tenant.tenantKey);
    return { kind: "ok", accounts };
  } catch {
    return { kind: "error" };
  }
}

function providerLabel(
  kind: string,
  t: Awaited<ReturnType<typeof getTranslations>>,
): string {
  switch (kind) {
    case "claude":
      return t("providerClaude");
    case "anthropic-apikey":
      return t("providerAnthropicApiKey");
    case "codex":
      return t("providerCodex");
    case "openai-apikey":
      return t("providerOpenAiApiKey");
    default:
      return t("providerUnknown");
  }
}

function formatCreatedAt(
  createdAt: string | undefined,
  formatter: Intl.DateTimeFormat,
  fallback: string,
): string {
  if (!createdAt) return fallback;
  const date = new Date(createdAt);
  if (Number.isNaN(date.getTime())) return fallback;
  return formatter.format(date);
}
