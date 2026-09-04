import { Suspense } from "react";
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
import { loadMachineUsage, MachineUsageSection } from "./machine-usage";
import {
  coderouterOrganizationFromCookieHeader,
} from "@/services/coderouter/organizationScope";
import {
  listClaudeAccounts,
  type ClaudeAccountDescription,
} from "@/services/coderouter/claudeUpstream";
import {
  AddAiAccountForms,
  DeleteAiAccountButton,
} from "../components/ai-account-forms";
import { ClaudeUpstreamSection } from "../components/claude-upstream-forms";
import { CoderouterPageHeader } from "../components/dashboard-page-headers";
import { withPrioritySpan } from "@/services/telemetry";
import { withStackAuthSpan } from "@/services/auth/stackTelemetry";

// The page resolves as one server render. Keeping the auth and data work in
// this Suspense boundary prevents a header-only response while the private
// content is still loading.
export const instant = true;
// The page reads the live browser session and team grants. Do not put a
// private RSC response in the prefetch cache before the click is authorized.
export const prefetch = "force-disabled";

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

export default function CoderouterOverviewPage(props: PageProps) {
  if (!isStackConfigured()) {
    redirect("/");
  }

  return (
    <Suspense fallback={null}>
      <ResolvedCoderouterOverviewContent {...props} />
    </Suspense>
  );
}

async function ResolvedCoderouterOverviewContent({ params, searchParams }: PageProps) {
  // Framework promises are not stable cache keys across prerender phases.
  const [{ locale }, { team: teamParam }] = await Promise.all([params, searchParams]);
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;

  return <CoderouterOverviewContent locale={locale} team={team} />;
}

type CoderouterAuthorization = {
  readonly teams: readonly DashboardTeam[];
  readonly selectedTeam: DashboardTeam;
  readonly accessToken: string;
};

type CoderouterAuthorizationResult =
  | { readonly kind: "authorized"; readonly value: CoderouterAuthorization }
  | { readonly kind: "missing" }
  | { readonly kind: "noTeams" }
  | { readonly kind: "unavailable" };

export async function CoderouterOverviewContent({
  locale,
  team,
}: {
  locale: string;
  team?: string;
}) {
  // Authorization and the access token are resolved for every request. There
  // is no private page cache here, so a prefetched response cannot outlive a
  // team grant or expose management controls after revocation.
  const requestHeaders = await headers();
  const authorization = await withPrioritySpan(
    "cmux-coderouter-dashboard",
    "cmux.coderouter.auth",
    { "http.route": "/dashboard/coderouter", "cmux.locale": locale },
    () => resolveCoderouterAuthorization(requestHeaders, team),
  );
  if (authorization.kind === "unavailable") {
    return renderCoderouterLoadError(locale);
  }
  if (authorization.kind === "missing") {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/coderouter")));
  }
  if (authorization.kind === "noTeams") {
    redirect("/dashboard");
  }

  const { teams, selectedTeam, accessToken } = authorization.value;
  const [tPage, t, accountState, metrics, claudeUpstream, machineUsage] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.coderouter" }),
    getTranslations({ locale, namespace: "dashboard.aiAccounts" }),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.accounts",
      { "cmux.team_scope": "selected" },
      () => loadAccounts(selectedTeam, accessToken),
    ),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.team_metrics",
      { "cmux.team_scope": "selected" },
      () => loadCoderouterTeamMetrics(selectedTeam.id),
    ),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.claude_upstream",
      { "cmux.team_scope": "selected" },
      () => loadClaudeUpstream(selectedTeam.id),
    ),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.machine_usage",
      { "cmux.team_scope": "selected" },
      () => loadMachineUsage(selectedTeam.id),
    ),
  ]);
  const dateFormatter = new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  });

  return (
    <CoderouterPageFrame>
      <div>
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

        <ClaudeUpstreamSection
          teamId={selectedTeam.id}
          accounts={claudeUpstream.kind === "ok" ? claudeUpstream.accounts : []}
          canManage={selectedTeam.manageAccounts}
          loadFailed={claudeUpstream.kind === "error"}
        />

        <MachineUsageSection
          locale={locale}
          t={tPage}
          teamName={selectedTeam.name}
          usage={machineUsage}
        />

        {selectedTeam.manageAccounts ? (
          <section className="mb-4">
            <div className="mb-2">
              <h2 className="text-sm font-medium">{t("addAccountsTitle")}</h2>
            </div>
            <AddAiAccountForms />
          </section>
        ) : null}

        {accountState.kind === "notConfigured" ? (
          <StatusPanel title={t("notConfiguredTitle")} body={t("notConfiguredBody")} />
        ) : accountState.kind === "migrationPending" ? (
          <StatusPanel title={t("migrationPendingTitle")} body={t("migrationPendingBody")} />
        ) : accountState.kind === "error" ? (
          <StatusPanel title={t("loadErrorTitle")} body={t("loadErrorBody")} />
        ) : (
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
        )}
      </div>
    </CoderouterPageFrame>
  );
}

async function resolveCoderouterAuthorization(
  requestHeaders: Headers,
  requestedTeamId: string | undefined,
): Promise<CoderouterAuthorizationResult> {
  try {
    const authenticated = await withSubrouterAuthorizationDeadline(
      async (signal) => {
        const user = await verifySubrouterRequest(
          new Request("https://cmux.com/dashboard/coderouter", {
            headers: Object.fromEntries(requestHeaders.entries()),
          }),
          signal,
          { allowCookie: true, listAllTeams: true },
        );
        if (!user) return null;
        const [authorized, authJson] = await Promise.all([
          authorizedSubrouterTeams(user),
          withStackAuthSpan(
            "get_auth_json",
            () => getStackServerApp().getAuthJson({
              tokenStore: {
                headers: {
                  get: (name: string) => requestHeaders.get(name),
                },
              },
            }),
            { "cmux.auth.flow": "coderouter_dashboard" },
          ).catch(() => {
            throw new SubrouterAuthorizationUnavailableError(
              "Stack session refresh unavailable",
            );
          }),
        ]);
        return {
          user,
          authorized,
          accessToken: authJson?.accessToken ?? null,
        };
      },
    );
    if (!authenticated) return { kind: "missing" };

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
      return { kind: "noTeams" };
    }
    const accessToken = authenticated.accessToken;
    if (!accessToken) return { kind: "missing" };
    const selectedTeam = selectTeam(
      teams,
      requestedTeamId,
      coderouterOrganizationFromCookieHeader(
        requestHeaders.get("cookie"),
        authenticated.user.id,
      ),
      authenticated.user.selectedTeamId,
    );
    return {
      kind: "authorized",
      value: {
        teams,
        selectedTeam,
        accessToken,
      },
    };
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    return { kind: "unavailable" };
  }
}

async function renderCoderouterLoadError(locale: string) {
  const t = await getTranslations({ locale, namespace: "dashboard.aiAccounts" });
  return (
    <CoderouterPageFrame>
      <StatusPanel title={t("loadErrorTitle")} body={t("loadErrorBody")} />
    </CoderouterPageFrame>
  );
}

function CoderouterPageFrame({ children }: React.PropsWithChildren) {
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <CoderouterPageHeader />
      {children}
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

type ClaudeUpstreamState =
  | { readonly kind: "ok"; readonly accounts: readonly ClaudeAccountDescription[] }
  | { readonly kind: "error" };

async function loadClaudeUpstream(teamId: string): Promise<ClaudeUpstreamState> {
  try {
    return { kind: "ok", accounts: await listClaudeAccounts(teamId) };
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
