"use client";

import type { CurrentUser, OAuthProvider } from "@hexclave/next";
import { KnownErrors } from "@hexclave/shared";
import { useTranslations } from "next-intl";
import { useState } from "react";
import {
  ActionMenu,
  Badge,
  ConfirmDialog,
  InlineError,
  SettingsPanel,
  useAsyncAction,
} from "@/dashboard-app/components/settings-ui";
import { isOnlySignInMethod } from "../../lib/sign-in-methods";
import { signInFacts } from "./sign-in-facts";

const PROVIDER_NAMES: Record<string, string> = {
  github: "GitHub",
  google: "Google",
  microsoft: "Microsoft",
  apple: "Apple",
  gitlab: "GitLab",
  bitbucket: "Bitbucket",
  discord: "Discord",
  facebook: "Facebook",
  linkedin: "LinkedIn",
  x: "X",
  twitch: "Twitch",
  spotify: "Spotify",
};

export function providerDisplayName(type: string): string {
  return PROVIDER_NAMES[type] ?? type.charAt(0).toUpperCase() + type.slice(1);
}

/**
 * Linked OAuth providers (not in Hexclave's account settings). Lists each
 * provider with its account email, toggles sign-in, and unlinks with a
 * confirmation. The last sign-in method can be neither turned off nor
 * removed.
 */
export function ConnectedAccountsSection({ user }: { readonly user: CurrentUser }) {
  const t = useTranslations("dashboard.settings.auth.connected");
  const providers = user.useOAuthProviders();
  const [removing, setRemoving] = useState<OAuthProvider | null>(null);
  const [run, state] = useAsyncAction(t("actionError"), (error) =>
    KnownErrors.OAuthProviderAccountIdAlreadyUsedForSignIn.isInstance(error) ? t("usedBySomeoneElse") : null,
  );
  if (providers.length === 0) return null;

  const signInCount = providers.filter((provider) => provider.allowSignIn).length;
  const onlyMethod = isOnlySignInMethod("oauth", signInFacts(user, signInCount));

  const setSignIn = (provider: OAuthProvider, allowSignIn: boolean) =>
    run(async () => {
      const result = await provider.update({ allowSignIn });
      if (result.status === "error") throw result.error;
    });

  return (
    <SettingsPanel title={t("title")} description={t("description")}>
      <ul className="divide-y divide-border border border-border">
        {providers.map((provider) => {
          const guarded = provider.allowSignIn && onlyMethod;
          return (
            <li key={provider.id} className="flex items-center justify-between gap-3 px-3 py-2">
              <div className="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-center sm:gap-3">
                <span className="font-medium">{providerDisplayName(provider.type)}</span>
                {provider.email ? <span className="min-w-0 truncate text-muted">{provider.email}</span> : null}
                {provider.allowSignIn ? <Badge tone="outline">{t("usedForSignIn")}</Badge> : null}
              </div>
              <ActionMenu
                label={t("actionsLabel", { provider: providerDisplayName(provider.type) })}
                disabled={state.pending}
                items={[
                  provider.allowSignIn
                    ? {
                        id: "stop",
                        label: t("stopUsingForSignIn"),
                        onSelect: () => void setSignIn(provider, false),
                        disabled: guarded,
                        disabledReason: guarded ? t("lastMethod") : undefined,
                      }
                    : { id: "use", label: t("useForSignIn"), onSelect: () => void setSignIn(provider, true) },
                  {
                    id: "remove",
                    label: t("remove"),
                    danger: true,
                    onSelect: () => setRemoving(provider),
                    disabled: guarded,
                    disabledReason: guarded ? t("lastMethod") : undefined,
                  },
                ]}
              />
            </li>
          );
        })}
      </ul>
      <InlineError message={state.error} />
      <ConfirmDialog
        open={removing !== null}
        onOpenChange={(open) => {
          if (!open) setRemoving(null);
        }}
        title={t("removeTitle", { provider: providerDisplayName(removing?.type ?? "") })}
        description={t("removeBody")}
        confirmLabel={t("remove")}
        errorMessage={t("actionError")}
        onConfirm={async () => {
          await removing?.delete();
        }}
      />
    </SettingsPanel>
  );
}
