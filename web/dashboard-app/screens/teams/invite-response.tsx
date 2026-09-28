"use client";

import { useStackApp } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { InlineError } from "@/dashboard-app/components/settings-ui/feedback";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { localeHref } from "@/dashboard-app/lib/locale-href";

/** What an invitation page knows before and after the viewer answers it. */
export type InviteResponseState =
  | { readonly kind: "loading" }
  | { readonly kind: "ready"; readonly teamName: string | null }
  | { readonly kind: "alreadyMember"; readonly teamName: string | null }
  | { readonly kind: "mismatch" }
  | { readonly kind: "invalid" };

/**
 * Shared by `/dashboard/team/accept` (email invitation) and `/join/[token]`
 * (invite link). Presentational: the caller owns fetching and joining.
 */
export function InviteResponseCard({
  state,
  viewerEmail,
  pending = false,
  error,
  onJoin,
  returnPath,
  locale,
}: {
  readonly state: InviteResponseState;
  readonly viewerEmail: string | null;
  readonly pending?: boolean;
  readonly error?: string | null;
  readonly onJoin: () => void;
  /** Localized-free path of this page, used for "switch account". */
  readonly returnPath: string;
  readonly locale: string;
}) {
  const t = useTranslations("teamInvite");
  return (
    <section data-testid={`invite-${state.kind}`} className="mx-auto w-full max-w-md border border-border p-5">
      <InviteBody state={state} viewerEmail={viewerEmail} returnPath={returnPath} locale={locale} />
      {state.kind === "ready" || state.kind === "alreadyMember" ? (
        <div className="mt-4 grid gap-2">
          <button type="button" disabled={pending} onClick={onJoin} className={settingsButtonClass("primary")}>
            {pending ? t("joining") : state.kind === "ready" ? t("join") : t("openTeam")}
          </button>
          {viewerEmail ? <p className="text-xs text-muted">{t("signedInAs", { email: viewerEmail })}</p> : null}
        </div>
      ) : null}
      <InlineError message={error} className="mt-3" />
    </section>
  );
}

function InviteBody({
  state,
  viewerEmail,
  returnPath,
  locale,
}: {
  readonly state: InviteResponseState;
  readonly viewerEmail: string | null;
  readonly returnPath: string;
  readonly locale: string;
}) {
  const t = useTranslations("teamInvite");
  switch (state.kind) {
    case "loading":
      return <p className="text-sm text-muted">{t("loading")}</p>;
    case "ready":
      return (
        <>
          <h1 className="text-sm font-medium">
            {state.teamName ? t("title", { team: state.teamName }) : t("titleUnknown")}
          </h1>
          <p className="mt-2 text-xs text-muted">{t("body")}</p>
        </>
      );
    case "alreadyMember":
      return (
        <>
          <h1 className="text-sm font-medium">
            {state.teamName ? t("alreadyMemberTitle", { team: state.teamName }) : t("alreadyMemberTitleUnknown")}
          </h1>
          <p className="mt-2 text-xs text-muted">{t("alreadyMemberBody")}</p>
        </>
      );
    case "mismatch":
      return (
        <>
          <h1 className="text-sm font-medium">{t("mismatchTitle")}</h1>
          <p className="mt-2 text-xs text-muted">
            {viewerEmail ? t("mismatchBody", { email: viewerEmail }) : t("mismatchBodyUnknown")}
          </p>
          <SwitchAccountButton returnPath={returnPath} locale={locale} />
        </>
      );
    case "invalid":
      return (
        <>
          <h1 className="text-sm font-medium">{t("invalidTitle")}</h1>
          <p className="mt-2 text-xs text-muted">{t("invalidBody")}</p>
          {/* A document link: this card also renders on `/join`, outside the dashboard router. */}
          <a href={localeHref(locale, "/dashboard/teams")} className={`${settingsButtonClass("secondary")} mt-4`}>
            {t("goToTeams")}
          </a>
        </>
      );
  }
}

/** Sign out, then sign back in and return to this invitation. */
function SwitchAccountButton({ returnPath, locale }: { readonly returnPath: string; readonly locale: string }) {
  const t = useTranslations("teamInvite");
  const stackApp = useStackApp();
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  return (
    <div className="mt-4 grid gap-2">
      <button
        type="button"
        disabled={pending}
        className={settingsButtonClass("primary")}
        onClick={async () => {
          setPending(true);
          setFailed(false);
          try {
            await stackApp.signOut({ redirectUrl: vaultSignInHref(localizedVaultPath(locale, returnPath)) });
          } catch {
            setPending(false);
            setFailed(true);
          }
        }}
      >
        {pending ? t("switching") : t("switchAccount")}
      </button>
      <InlineError message={failed ? t("switchFailed") : null} />
    </div>
  );
}
