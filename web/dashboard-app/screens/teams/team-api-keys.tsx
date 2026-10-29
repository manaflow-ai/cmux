"use client";

import { type Team as StackTeam, useUser } from "@hexclave/next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { EmptyState, SectionError } from "@/dashboard-app/components/page-states";
import { SettingsPanel } from "@/dashboard-app/components/settings-ui/settings-section";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { dashboardRefusal } from "@/dashboard-app/lib/refusal";
import { teamApiKeysQuery } from "@/dashboard-app/queries/teams";
import type { SettingsApiKey } from "@/dashboard-app/queries/settings";
import { CreateApiKeyDialog, ShowApiKeyDialog } from "@/dashboard-app/screens/settings/components/api-keys/api-key-dialogs";
import { type ApiKeyRow, ApiKeyTable } from "@/dashboard-app/screens/settings/components/api-keys/api-key-table";
import { useTeamContext } from "./team-shell";

type TeamApiKeyFirstView = Awaited<ReturnType<StackTeam["createApiKey"]>>;

/**
 * Team keys, read through the typed `teams.apiKeys` procedure (which checks
 * `$manage_api_keys` and the project switch). Creating and revoking keys run
 * on the client SDK under the viewer's own session.
 */
export function TeamApiKeys() {
  const t = useTranslations("dashboard.teams.apiKeys");
  const detail = useTeamContext();
  const keys = useQuery(teamApiKeysQuery(detail.team.id));
  if (keys.isPending) return <DashboardSectionSkeleton variant="table" columns={5} rows={3} />;
  if (keys.isError) {
    if (dashboardRefusal(keys.error)?.reason === "forbidden") return <EmptyState title={t("title")} body={t("forbidden")} />;
    return <SectionError error={keys.error} section={t("title")} onRetry={() => keys.refetch()} />;
  }
  if (!keys.data.enabled) return <EmptyState title={t("title")} body={t("disabled")} />;
  return <TeamApiKeysPanel teamId={detail.team.id} keys={keys.data.keys} />;
}

function TeamApiKeysPanel({ teamId, keys }: { readonly teamId: string; readonly keys: readonly SettingsApiKey[] }) {
  const t = useTranslations("dashboard.teams.apiKeys");
  const queryClient = useQueryClient();
  const user = useUser({ or: "redirect" });
  const [creating, setCreating] = useState(false);
  const [created, setCreated] = useState<TeamApiKeyFirstView | null>(null);
  const refresh = () => queryClient.invalidateQueries({ queryKey: teamApiKeysQuery(teamId).queryKey });
  const sdkTeam = async () => {
    const team = await user.getTeam(teamId);
    if (!team) throw new Error("team_not_found");
    return team;
  };
  const rows = keys.map((key): ApiKeyRow => ({
    id: key.id,
    description: key.description,
    createdAt: new Date(key.createdAt),
    expiresAt: key.expiresAt ? new Date(key.expiresAt) : undefined,
    value: { lastFour: key.lastFour },
    whyInvalid: () => key.whyInvalid,
    revoke: async () => {
      const sdk = (await (await sdkTeam()).listApiKeys()).find((candidate) => candidate.id === key.id);
      if (!sdk) throw new Error("api_key_not_found");
      await sdk.revoke();
      await refresh();
    },
  }));

  return (
    <SettingsPanel
      title={t("title")}
      description={t("description")}
      actions={
        <button type="button" onClick={() => setCreating(true)} className={settingsButtonClass("primary", "sm")}>
          {t("create")}
        </button>
      }
    >
      <ApiKeyTable apiKeys={rows} />
      <CreateApiKeyDialog
        open={creating}
        onOpenChange={setCreating}
        createApiKey={async (options) => {
          const key = await (await sdkTeam()).createApiKey(options);
          await refresh();
          return key;
        }}
        onCreated={setCreated}
      />
      <ShowApiKeyDialog apiKey={created} onClose={() => setCreated(null)} />
    </SettingsPanel>
  );
}
