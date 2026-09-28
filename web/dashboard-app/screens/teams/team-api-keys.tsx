"use client";

import { type CurrentUser, type Team as StackTeam, useStackApp, useUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { Suspense, useState } from "react";
import { SettingsPanel } from "@/dashboard-app/components/settings-ui/settings-section";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { CreateApiKeyDialog, ShowApiKeyDialog } from "@/dashboard-app/screens/settings/components/api-keys/api-key-dialogs";
import { ApiKeyTable } from "@/dashboard-app/screens/settings/components/api-keys/api-key-table";
import { TeamNotFound, useTeamContext } from "./team-shell";

export function TeamApiKeys() {
  return (
    <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>
      <TeamApiKeysGate />
    </Suspense>
  );
}

/**
 * Team keys need both the project switch and the viewer's Stack permission.
 * The tab is hidden otherwise; a direct visit gets the not-found card.
 */
function TeamApiKeysGate() {
  const detail = useTeamContext();
  const project = useStackApp().useProject();
  const user = useUser({ or: "redirect" });
  const team = user.useTeam(detail.team.id);
  if (!team || !project.config.allowTeamApiKeys) return <TeamNotFound />;
  return <TeamApiKeysPermissionGate user={user} team={team} />;
}

function TeamApiKeysPermissionGate({ user, team }: { readonly user: CurrentUser; readonly team: StackTeam }) {
  const permission = user.usePermission(team, "$manage_api_keys");
  if (!permission) return <TeamNotFound />;
  return <TeamApiKeysPanel team={team} />;
}

type TeamApiKeyFirstView = Awaited<ReturnType<StackTeam["createApiKey"]>>;

/** Same dialogs and table as account API keys, bound to the team's keys. */
function TeamApiKeysPanel({ team }: { readonly team: StackTeam }) {
  const t = useTranslations("dashboard.teams.apiKeys");
  const apiKeys = team.useApiKeys();
  const [creating, setCreating] = useState(false);
  const [created, setCreated] = useState<TeamApiKeyFirstView | null>(null);

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
      <ApiKeyTable apiKeys={apiKeys} />
      <CreateApiKeyDialog
        open={creating}
        onOpenChange={setCreating}
        createApiKey={(options) => team.createApiKey(options)}
        onCreated={setCreated}
      />
      <ShowApiKeyDialog apiKey={created} onClose={() => setCreated(null)} />
    </SettingsPanel>
  );
}
