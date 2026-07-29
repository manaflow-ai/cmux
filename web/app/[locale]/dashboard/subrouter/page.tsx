import { getTranslations } from "next-intl/server";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { Link } from "@/i18n/navigation";
import { cloudDb } from "@/db/client";
import { isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  type SubrouterAccount,
} from "@/services/subrouter/client";
import { getTenantForTeam } from "@/services/subrouter/tenants";
import {
  authorizedSubrouterTeams,
} from "@/services/subrouter/routeHelpers";
import {
  isSubrouterAuthorizationError,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";
import {
  AddAiAccountForms,
  DeleteAiAccountButton,
} from "../components/ai-account-forms";

export const dynamic = "force-dynamic";

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
};

type DashboardTeam = {
  readonly id: string;
  readonly name: string;
  readonly manageAccounts: boolean;
};

type AccountState =
  | { readonly kind: "ok"; readonly accounts: readonly SubrouterAccount[] }
  | { readonly kind: "notConfigured" }
  | { readonly kind: "error" };

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.aiAccounts" });
  const alternates = buildAlternates(locale, "/dashboard/subrouter");
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

export default async function SubrouterOverviewPage({ params, searchParams }: PageProps) {
  const [{ locale }, { team: teamParam }] = await Promise.all([params, searchParams]);
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const requestHeaders = await headers();
  let authorized: Awaited<ReturnType<typeof authorizedSubrouterTeams>> | null;
  try {
    authorized = await withSubrouterAuthorizationDeadline(
      async (signal) => {
        const user = await verifySubrouterRequest(
          new Request("https://cmux.com/dashboard/subrouter", {
            headers: Object.fromEntries(requestHeaders.entries()),
          }),
          signal,
          { allowCookie: true, listAllTeams: true },
        );
        return user ? authorizedSubrouterTeams(user) : null;
      },
    );
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    const [tPage, t] = await Promise.all([
      getTranslations({ locale, namespace: "dashboard.subrouter" }),
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
  if (!authorized) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/subrouter")));
  }

  const [tPage, t] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.subrouter" }),
    getTranslations({ locale, namespace: "dashboard.aiAccounts" }),
  ]);
  const teams = authorized
    .filter((candidate) => candidate.use || candidate.manageAccounts)
    .map((candidate) => ({
      id: candidate.teamId,
      name: candidate.teamName,
      manageAccounts: candidate.manageAccounts,
    }));
  if (teams.length === 0) {
    redirect("/dashboard");
  }
  const selectedTeam = selectTeam(teams, team);
  const accountState = await loadAccounts(selectedTeam);
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

          {selectedTeam.manageAccounts ? (
            <aside>
              <h2 className="mb-2 text-sm font-medium">{t("addAccountsTitle")}</h2>
              <AddAiAccountForms teamId={selectedTeam.id} />
            </aside>
          ) : null}
        </div>
      )}
    </div>
  );
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
