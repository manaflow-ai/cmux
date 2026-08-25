import { getTranslations } from "next-intl/server";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { Link } from "@/i18n/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import type { SubrouterAccount } from "@/services/subrouter/types";
import { hostedSubrouterCutoverReadyForTeam } from "@/services/subrouter/cutover";
import { createHostedSubrouterClient } from "@/services/subrouter/hostedClient";
import {
  authorizedSubrouterTeams,
} from "@/services/subrouter/routeHelpers";
import {
  isSubrouterAuthorizationError,
  SubrouterAuthorizationUnavailableError,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";
import {
  loadCoderouterTeamMetrics,
  type CoderouterTeamMetrics,
} from "@/services/coderouter/teamMetrics";
import {
  coderouterOrganizationFromCookieHeader,
} from "@/services/coderouter/organizationScope";
import {
  AddAiAccountForms,
  DeleteAiAccountButton,
} from "../components/ai-account-forms";


type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
};

type DashboardTeam = {
  readonly id: string;
  readonly name: string;
  readonly use: boolean;
  readonly manageAccounts: boolean;
  readonly personal: boolean;
};

type AccountState =
  | { readonly kind: "ok"; readonly accounts: readonly SubrouterAccount[] }
  | { readonly kind: "migrationPending" }
  | { readonly kind: "notConfigured" }
  | { readonly kind: "error" };

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.coderouter" });
  const alternates = buildAlternates(locale, "/dashboard/coderouter");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function CoderouterOverviewPage({ params, searchParams }: PageProps) {
  const [{ locale }, { team: teamParam }] = await Promise.all([params, searchParams]);
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const requestHeaders = await headers();
  const tokenStore = {
    headers: { get: (name: string) => requestHeaders.get(name) },
  };
  let authenticated: {
    readonly authorized: Awaited<ReturnType<typeof authorizedSubrouterTeams>>;
    readonly accessToken: string | null;
    readonly scopedTeamId: string | null;
    readonly selectedTeamId: string | null;
  } | null;
  try {
    authenticated = await withSubrouterAuthorizationDeadline(
      async (signal) => {
        const user = await verifySubrouterRequest(
          new Request("https://cmux.com/dashboard/coderouter", {
            headers: Object.fromEntries(requestHeaders.entries()),
          }),
          signal,
          { allowCookie: true, listAllTeams: true },
        );
        if (!user) return null;
        const authorized = await authorizedSubrouterTeams(user);
        let authJson: Awaited<ReturnType<ReturnType<typeof getStackServerApp>["getAuthJson"]>>;
        try {
          authJson = await getStackServerApp().getAuthJson({ tokenStore });
        } catch {
          throw new SubrouterAuthorizationUnavailableError(
            "Stack session refresh unavailable",
          );
        }
        return {
          authorized,
          accessToken: authJson?.accessToken ?? null,
          scopedTeamId: coderouterOrganizationFromCookieHeader(
            requestHeaders.get("cookie"),
            user.id,
          ),
          selectedTeamId: user.selectedTeamId,
        };
      },
    );
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    const [tPage, t] = await Promise.all([
      getTranslations({ locale, namespace: "dashboard.coderouter" }),
      getTranslations({ locale, namespace: "dashboard.aiAccounts" }),
    ]);
    return (
      <div className="mx-auto w-full max-w-5xl px-3 py-4">
        <DashboardHeader
          title={tPage("title")}
          description={tPage("description")}
        />
        <StatusPanel title={t("loadErrorTitle")} body={t("loadErrorBody")} />
      </div>
    );
  }
  if (!authenticated) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/coderouter")));
  }
  if (!authenticated.accessToken) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/coderouter")));
  }

  const [tPage, t] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.coderouter" }),
    getTranslations({ locale, namespace: "dashboard.aiAccounts" }),
  ]);
  const teams = authenticated.authorized
    .filter((candidate) => candidate.use || candidate.manageAccounts)
    .map((candidate) => ({
      id: candidate.teamId,
      name: candidate.teamName,
      use: candidate.use,
      manageAccounts: candidate.manageAccounts,
      personal: candidate.personal,
    }));
  if (teams.length === 0) {
    redirect("/dashboard");
  }
  const selectedTeam = selectTeam(
    teams,
    team,
    authenticated.scopedTeamId,
    authenticated.selectedTeamId,
  );
  const [accountState, metrics] = await Promise.all([
    loadAccounts(selectedTeam, authenticated.accessToken),
    loadCoderouterTeamMetrics(selectedTeam.id),
  ]);
  const dateFormatter = new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  });

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <DashboardHeader
        title={tPage("title")}
        description={tPage("description")}
      />

      <section className="mb-4 border border-border p-3">
        <div className="mb-2 text-xs text-muted">{t("teamSwitcherLabel")}</div>
        <div className="flex flex-wrap gap-3">
          {teams.map((candidate) => {
            const selected = candidate.id === selectedTeam.id;
            return (
              <Link
                key={candidate.id}
                href={`/dashboard/coderouter?team=${encodeURIComponent(candidate.id)}`}
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

      <TeamMetricsSection
        locale={locale}
        metrics={metrics}
        teamName={selectedTeam.name}
      />

      {accountState.kind === "notConfigured" ? (
        <StatusPanel title={t("notConfiguredTitle")} body={t("notConfiguredBody")} />
      ) : accountState.kind === "migrationPending" ? (
        <StatusPanel title={t("migrationPendingTitle")} body={t("migrationPendingBody")} />
      ) : accountState.kind === "error" ? (
        <StatusPanel title={t("loadErrorTitle")} body={t("loadErrorBody")} />
      ) : (
        <div>
          {selectedTeam.manageAccounts ? (
            <section className="mb-4">
              <div className="mb-2">
                <h2 className="text-sm font-medium">{t("addAccountsTitle")}</h2>
              </div>
              <AddAiAccountForms />
            </section>
          ) : null}

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
                  {selectedTeam.manageAccounts ? (
                    <div className="text-right">{t("actionsColumn")}</div>
                  ) : <div />}
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
                    {selectedTeam.manageAccounts ? (
                      <DeleteAiAccountButton
                        teamId={selectedTeam.id}
                        accountId={account.id}
                      />
                    ) : <div />}
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>
      )}
    </div>
  );
}

function TeamMetricsSection({
  locale,
  metrics,
  teamName,
}: {
  readonly locale: string;
  readonly metrics: CoderouterTeamMetrics;
  readonly teamName: string;
}) {
  const copy = metricsCopy(locale);
  if (metrics.kind === "unavailable") {
    return (
      <section className="mb-4 border border-border p-3">
        <h2 className="text-sm font-medium">{copy.title}</h2>
        <p className="mt-1 text-xs text-muted">{copy.unavailable}</p>
      </section>
    );
  }

  const number = new Intl.NumberFormat(locale, {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  const currency = new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
  const percent = new Intl.NumberFormat(locale, {
    style: "percent",
    maximumFractionDigits: 0,
  });
  const coverage = metrics.totals.totalTokens > 0
    ? metrics.totals.pricedTokens / metrics.totals.totalTokens
    : 1;
  const maxDailyTokens = Math.max(
    1,
    ...metrics.daily.map((day) => day.totalTokens),
  );

  return (
    <section className="mb-4 border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{copy.title}</h2>
          <p className="mt-1 text-xs text-muted">
            {copy.scope.replace("{team}", teamName)}
          </p>
        </div>
        <span className="font-mono text-[11px] text-muted">
          {copy.period.replace("{days}", String(metrics.periodDays))}
        </span>
      </div>

      <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
        <MetricCard
          label={copy.tokens}
          value={number.format(metrics.totals.totalTokens)}
        />
        <MetricCard
          label={copy.inputTokens}
          value={number.format(metrics.totals.inputTokens)}
        />
        <MetricCard
          label={copy.outputTokens}
          value={number.format(metrics.totals.outputTokens)}
        />
        <MetricCard
          label={copy.apiEquivalent}
          value={currency.format(metrics.totals.apiEquivalentUsd)}
        />
        <MetricCard
          label={copy.pricingCoverage}
          value={percent.format(coverage)}
        />
      </div>

      <div
        className="mt-3 flex h-24 items-end gap-px border border-border px-2 pt-2"
        role="img"
        aria-label={copy.chartLabel}
      >
        {metrics.daily.map((day) => {
          const height = day.totalTokens === 0
            ? 0
            : Math.max(3, (day.totalTokens / maxDailyTokens) * 100);
          return (
            <div
              key={day.day}
              className="min-w-0 flex-1 bg-foreground/70"
              style={{ height: `${height}%` }}
              title={`${day.day}: ${number.format(day.totalTokens)} ${copy.tokens.toLowerCase()}`}
            />
          );
        })}
      </div>

      <p className="mt-2 text-[11px] leading-5 text-muted">
        {copy.privacy}
      </p>
      <p className="text-[11px] leading-5 text-muted">
        {copy.estimate.replace("{version}", metrics.rateCardVersion)}
      </p>
    </section>
  );
}

function MetricCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="border border-border p-2">
      <div className="text-[11px] text-muted">{label}</div>
      <div className="mt-1 font-mono text-lg tabular-nums">{value}</div>
    </div>
  );
}

function metricsCopy(locale: string) {
  if (locale === "ja") {
    return {
      title: "30日間の使用状況",
      scope: "{team} のチーム集計",
      period: "過去{days}日間",
      inputTokens: "入力トークン",
      outputTokens: "出力トークン",
      tokens: "合計トークン",
      apiEquivalent: "API換算額",
      pricingCoverage: "価格対応率",
      chartLabel: "日別のCodeRouterトークン使用量",
      privacy:
        "プロンプト、出力、アカウントラベル、メンバーIDは記録・表示しません。",
      estimate:
        "API換算額は公開定価（レート表 {version}）による推定で、実際の請求額ではありません。価格不明のモデルは換算額から除外されます。",
      unavailable: "チーム使用状況は現在利用できません。",
    };
  }
  return {
    title: "30-day usage",
    scope: "Team aggregate for {team}",
    period: "Last {days} days",
    inputTokens: "Input tokens",
    outputTokens: "Output tokens",
    tokens: "Total tokens",
    apiEquivalent: "API-equivalent value",
    pricingCoverage: "Pricing coverage",
    chartLabel: "Daily CodeRouter token usage",
    privacy:
      "No prompts, outputs, account labels, or member identities are recorded or shown.",
    estimate:
      "API-equivalent value is an estimate using public list prices (rate card {version}), not actual spend. Models without a known price are excluded.",
    unavailable: "Team usage is temporarily unavailable.",
  };
}

function DashboardHeader({
  title,
  description,
}: {
  title: string;
  description: string;
}) {
  return (
    <div className="mb-4 border-b border-border pb-3">
      <h1 className="text-sm font-medium">{title}</h1>
      <p className="mt-1 max-w-2xl text-muted">{description}</p>
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

function selectTeam(
  teams: readonly DashboardTeam[],
  requestedTeamId: string | undefined,
  scopedTeamId: string | null,
  selectedTeamId: string | null,
): DashboardTeam {
  const requested = requestedTeamId?.trim();
  if (requested) {
    const selected = teams.find((team) => team.id === requested);
    if (selected) return selected;
  }
  if (scopedTeamId) {
    const scoped = teams.find((team) => team.id === scopedTeamId);
    if (scoped) return scoped;
  }
  if (selectedTeamId) {
    const selected = teams.find((team) => team.id === selectedTeamId);
    if (selected) return selected;
  }
  const personal = teams.find((team) => team.personal);
  if (personal) return personal;
  return teams[0];
}

async function loadAccounts(
  team: DashboardTeam,
  accessToken: string,
): Promise<AccountState> {
  try {
    if (!await hostedSubrouterCutoverReadyForTeam(team.id)) {
      return { kind: "migrationPending" };
    }
    const client = createHostedSubrouterClient();
    if (!client.tenantControlConfigured) {
      return { kind: "notConfigured" };
    }
    const tenant = await client.exchangeTeam(accessToken, {
      teamId: team.id,
      teamName: team.name,
      use: team.use,
      manageAccounts: team.manageAccounts,
    });
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
