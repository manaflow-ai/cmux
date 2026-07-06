import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { cloudDb } from "../../../../db/client";
import { getStackServerApp } from "../../../lib/stack";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  type SubrouterAccount,
} from "../../../../services/subrouter/client";
import { getTenantForTeam } from "../../../../services/subrouter/tenants";
import { SiteHeader } from "../../components/site-header";
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
    alternates: buildAlternates(locale, "/dashboard/ai-accounts"),
  };
}

export default async function AiAccountsPage({ params, searchParams }: PageProps) {
  const { locale } = await params;
  const { team: teamParam } = await searchParams;
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;
  const t = await getTranslations({ locale, namespace: "dashboard.aiAccounts" });
  const stackUser = await getStackServerApp().getUser({ or: "redirect" }) as StackUserLike;
  const teams = await dashboardTeams(stackUser, t("personalTeam"));
  const selectedTeam = selectTeam(teams, team);
  const accountState = await loadAccounts(selectedTeam);
  const dateFormatter = new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  });

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto w-full max-w-6xl px-6 py-10">
        <div className="mb-8">
          <h1 className="mb-2 text-2xl font-semibold tracking-tight">
            {t("title")}
          </h1>
          <p className="max-w-3xl text-[15px] text-muted">
            {t("description")}
          </p>
        </div>

        <section className="mb-8 border-y border-border py-4">
          <div className="mb-3 text-xs font-medium uppercase text-muted">
            {t("teamSwitcherLabel")}
          </div>
          <div className="flex flex-wrap gap-2">
            {teams.map((candidate) => {
              const selected = candidate.id === selectedTeam.id;
              return (
                <Link
                  key={candidate.id}
                  href={`/dashboard/ai-accounts?team=${encodeURIComponent(candidate.id)}`}
                  className={`rounded-md border px-3 py-2 text-sm transition-colors ${
                    selected
                      ? "border-foreground bg-foreground text-background"
                      : "border-border hover:border-foreground"
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
          <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
            <section>
              <div className="mb-4 flex items-end justify-between gap-4">
                <div>
                  <h2 className="text-lg font-semibold tracking-tight">
                    {t("accountsTitle")}
                  </h2>
                  <p className="mt-1 text-sm text-muted">
                    {t("accountsCount", { count: accountState.accounts.length })}
                  </p>
                </div>
              </div>

              {accountState.accounts.length === 0 ? (
                <div className="rounded-lg border border-border p-6">
                  <div className="font-medium">{t("emptyTitle")}</div>
                  <p className="mt-2 text-sm text-muted">{t("emptyBody")}</p>
                </div>
              ) : (
                <div className="overflow-hidden rounded-lg border border-border">
                  <div className="hidden grid-cols-[3rem_1.2fr_1fr_1fr_auto] gap-4 border-b border-border bg-muted/20 px-4 py-3 text-xs font-medium uppercase text-muted md:grid">
                    <div>#</div>
                    <div>{t("providerColumn")}</div>
                    <div>{t("labelColumn")}</div>
                    <div>{t("createdColumn")}</div>
                    <div className="text-right">{t("actionsColumn")}</div>
                  </div>
                  {accountState.accounts.map((account, index) => {
                    const accountNumber = index + 1;
                    return (
                      <div
                        key={account.id}
                        className="grid gap-3 border-b border-border px-4 py-3 text-sm last:border-b-0 md:grid-cols-[3rem_1.2fr_1fr_1fr_auto] md:items-center md:gap-4"
                      >
                        <div className="font-mono text-xs font-medium text-muted md:text-sm">
                          <span className="md:hidden">#</span>
                          {accountNumber}
                        </div>
                        <div>
                          <div className="mb-1 text-xs font-medium uppercase text-muted md:hidden">
                            {t("providerColumn")}
                          </div>
                          <div className="font-medium">{providerLabel(account.kind, t)}</div>
                        </div>
                        <div className="min-w-0 truncate text-muted">
                          <div className="mb-1 text-xs font-medium uppercase text-muted md:hidden">
                            {t("labelColumn")}
                          </div>
                          {account.label || t("unlabeledAccount")}
                        </div>
                        <div className="text-muted">
                          <div className="mb-1 text-xs font-medium uppercase text-muted md:hidden">
                            {t("createdColumn")}
                          </div>
                          {formatCreatedAt(account.createdAt, dateFormatter, t("unknownCreatedAt"))}
                        </div>
                        <DeleteAiAccountButton
                          teamId={selectedTeam.id}
                          accountId={account.id}
                        />
                      </div>
                    );
                  })}
                </div>
              )}
            </section>

            <aside>
              <h2 className="mb-4 text-lg font-semibold tracking-tight">
                {t("addAccountsTitle")}
              </h2>
              <AddAiAccountForms teamId={selectedTeam.id} />
            </aside>
          </div>
        )}
      </main>
    </div>
  );
}

function StatusPanel({ title, body }: { title: string; body: string }) {
  return (
    <section className="rounded-lg border border-border p-6">
      <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
      <p className="mt-2 max-w-2xl text-sm text-muted">{body}</p>
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
