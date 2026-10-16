"use client";

import { useUser, type CurrentUser } from "@hexclave/next";
import { useSuspenseQuery } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { SettingsNotice, settingsButtonClass } from "@/dashboard-app/components/settings-ui";
import {
  type SettingsApiKey,
  settingsApiKeysQuery,
  settingsOverviewQuery,
  useRefreshSettings,
} from "@/dashboard-app/queries/settings";
import { type ApiKeyRow, ApiKeyTable } from "./api-keys/api-key-table";
import { CreateApiKeyDialog, ShowApiKeyDialog } from "./api-keys/api-key-dialogs";

type UserApiKeyFirstView = Awaited<ReturnType<CurrentUser["createApiKey"]>>;

/** `/dashboard/settings/api-keys`, gated by `allowUserApiKeys`. */
export function ApiKeySettings() {
  const t = useTranslations("dashboard.settings.apiKeys");
  const { project } = useSuspenseQuery(settingsOverviewQuery).data;
  const user = useUser({ or: "redirect" });
  if (!project.allowUserApiKeys) return <SettingsNotice>{t("disabled")}</SettingsNotice>;
  return <ApiKeysManager user={user} />;
}

function ApiKeysManager({ user }: { readonly user: CurrentUser }) {
  const t = useTranslations("dashboard.settings.apiKeys");
  const refresh = useRefreshSettings();
  const apiKeys = useSuspenseQuery(settingsApiKeysQuery).data.map((key) => apiKeyRow(key, user, refresh));
  const [creating, setCreating] = useState(false);
  const [created, setCreated] = useState<UserApiKeyFirstView | null>(null);

  return (
    <div className="flex flex-col gap-3">
      <div>
        <button type="button" onClick={() => setCreating(true)} className={settingsButtonClass("primary", "sm")}>
          {t("create")}
        </button>
      </div>
      <ApiKeyTable apiKeys={apiKeys} />
      <CreateApiKeyDialog
        open={creating}
        onOpenChange={setCreating}
        createApiKey={async (options) => {
          const created = await user.createApiKey(options);
          await refresh();
          return created;
        }}
        onCreated={setCreated}
      />
      <ShowApiKeyDialog apiKey={created} onClose={() => setCreated(null)} />
    </div>
  );
}

/** A table row for a typed key; revoking finds the SDK key so it runs with the user's own session. */
function apiKeyRow(key: SettingsApiKey, user: CurrentUser, refresh: () => Promise<void>): ApiKeyRow {
  return {
    id: key.id,
    description: key.description,
    createdAt: new Date(key.createdAt),
    expiresAt: key.expiresAt ? new Date(key.expiresAt) : undefined,
    value: { lastFour: key.lastFour },
    whyInvalid: () => key.whyInvalid,
    revoke: async () => {
      const sdk = (await user.listApiKeys()).find((candidate) => candidate.id === key.id);
      if (!sdk) throw new Error("api_key_not_found");
      await sdk.revoke();
      await refresh();
    },
  };
}
