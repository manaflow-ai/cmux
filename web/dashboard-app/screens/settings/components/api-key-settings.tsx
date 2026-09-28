"use client";

import { useStackApp, useUser, type CurrentUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { SettingsNotice, settingsButtonClass } from "@/dashboard-app/components/settings-ui";
import { ApiKeyTable } from "./api-keys/api-key-table";
import { CreateApiKeyDialog, ShowApiKeyDialog } from "./api-keys/api-key-dialogs";

type UserApiKeyFirstView = Awaited<ReturnType<CurrentUser["createApiKey"]>>;

/** `/dashboard/settings/api-keys`, gated by `allowUserApiKeys`. */
export function ApiKeySettings() {
  const t = useTranslations("dashboard.settings.apiKeys");
  const project = useStackApp().useProject();
  const user = useUser({ or: "redirect" });
  if (!project.config.allowUserApiKeys) return <SettingsNotice>{t("disabled")}</SettingsNotice>;
  return <ApiKeysManager user={user} />;
}

function ApiKeysManager({ user }: { readonly user: CurrentUser }) {
  const t = useTranslations("dashboard.settings.apiKeys");
  const apiKeys = user.useApiKeys();
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
        createApiKey={(options) => user.createApiKey(options)}
        onCreated={setCreated}
      />
      <ShowApiKeyDialog apiKey={created} onClose={() => setCreated(null)} />
    </div>
  );
}
