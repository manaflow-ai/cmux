import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { Link } from "@/i18n/navigation";
import { applyAcceptedInvitationRole, type StackTeamUserLike } from "@/services/team/invites";

export const dynamic = "force-dynamic";

type StackAcceptUser = StackTeamUserLike & {
  acceptTeamInvitation?: (code: string) => Promise<unknown>;
  listTeamInvitations?: () => Promise<readonly {
    id: string;
    teamId?: string;
    accept?: () => Promise<void>;
  }[]>;
};

export default async function TeamInviteAcceptPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<{ code?: string | string[]; invitation?: string | string[] }>;
}) {
  const [{ locale }, query] = await Promise.all([
    params,
    searchParams ?? Promise.resolve({} as { code?: string | string[]; invitation?: string | string[] }),
  ]);
  const code = Array.isArray(query.code) ? query.code[0] : query.code;
  const invitationId = Array.isArray(query.invitation) ? query.invitation[0] : query.invitation;
  const acceptQuery = code
    ? `code=${encodeURIComponent(code)}`
    : `invitation=${encodeURIComponent(invitationId ?? "")}`;
  const acceptPath = localizedVaultPath(locale, `/dashboard/team/accept?${acceptQuery}`);
  const t = await getTranslations({ locale, namespace: "dashboard.team.accept" });
  if (!isStackConfigured()) redirect("/");
  if (!code && !invitationId) {
    return <AcceptError title={t("badCodeTitle")} body={t("badCodeBody")} switchAccount={t("switchAccount")} />;
  }
  const user = await getStackServerApp().getUser({ or: "return-null" }) as StackAcceptUser | null;
  if (!user) redirect(vaultSignInHref(acceptPath));
  let acceptedInvitationId: string | null = null;
  let acceptedTeamId: string | null = null;
  try {
    if (code) {
      if (!user.acceptTeamInvitation) throw new Error("acceptTeamInvitation unavailable");
      const result = await user.acceptTeamInvitation(code);
      if (isStackResultError(result)) throw result.error;
    } else {
      if (!user.listTeamInvitations) throw new Error("listTeamInvitations unavailable");
      const invitation = (await user.listTeamInvitations()).find((candidate) => candidate.id === invitationId);
      if (!invitation?.accept) throw new Error("VerificationCodeError");
      await invitation.accept();
      acceptedInvitationId = invitation.id;
      acceptedTeamId = invitation.teamId ?? null;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/mismatch|email/i.test(message)) {
      return <AcceptError title={t("emailMismatchTitle")} body={t("emailMismatchBody")} switchAccount={t("switchAccount")} />;
    }
    return <AcceptError title={t("badCodeTitle")} body={t("badCodeBody")} switchAccount={t("switchAccount")} />;
  }
  if (acceptedInvitationId) {
    await applyAcceptedInvitationRole({ user, invitationId: acceptedInvitationId, teamId: acceptedTeamId });
  }
  redirect(localizedVaultPath(locale, "/dashboard/team?joined=1"));
}

function AcceptError({ title, body, switchAccount }: { title: string; body: string; switchAccount: string }) {
  return (
    <div className="mx-auto w-full max-w-2xl px-3 py-8">
      <section className="border border-border p-3">
        <h1 className="text-sm font-medium">{title}</h1>
        <p className="mt-2 text-sm text-muted">{body}</p>
        <Link
          href="/handler/sign-out-and-sign-in"
          className="mt-3 inline-block border border-border px-3 py-1.5 text-sm"
        >
          {switchAccount}
        </Link>
      </section>
    </div>
  );
}

function isStackResultError(value: unknown): value is { status: "error"; error: unknown } {
  return !!value &&
    typeof value === "object" &&
    (value as { status?: unknown }).status === "error";
}
