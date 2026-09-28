"use client";

import { useStackApp } from "@hexclave/next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLocale } from "next-intl";
import { useState } from "react";
import { useRouter } from "@/i18n/navigation";
import { invalidateTeamScope, teamApi, teamErrorCode } from "../../teams/team-api";
import { useTeamErrorText } from "../../teams/team-ui";
import { InviteResponseCard, type InviteResponseState } from "./invite-response";

export function acceptReturnPath(code: string): string {
  return `/dashboard/team/accept?${new URLSearchParams({ code }).toString()}`;
}

type InvitationDetails =
  | { readonly status: "ok"; readonly teamName: string }
  | { readonly status: "mismatch" }
  | { readonly status: "invalid" }
  | { readonly status: "unknown" };

/**
 * Map Stack's `getTeamInvitationDetails` result. Anything other than a
 * known refusal is "unknown": the Join button still works and the accept
 * route gives the authoritative answer.
 */
export function invitationDetailsFromResult(result: unknown): InvitationDetails {
  const value = result as { status?: string; data?: { teamDisplayName?: unknown }; error?: { errorCode?: unknown } } | null;
  if (value?.status === "ok" && typeof value.data?.teamDisplayName === "string") {
    return { status: "ok", teamName: value.data.teamDisplayName };
  }
  if (value?.status === "error") {
    if (value.error?.errorCode === "TEAM_INVITATION_EMAIL_MISMATCH") return { status: "mismatch" };
    return { status: "invalid" };
  }
  return { status: "unknown" };
}

/** Page state from what is known so far; a join refusal overrides the preview. */
export function acceptInviteState(input: {
  readonly code: string;
  readonly details: InvitationDetails | undefined;
  readonly joinFailure: string | null;
}): InviteResponseState {
  if (!input.code) return { kind: "invalid" };
  if (input.joinFailure === "email_mismatch") return { kind: "mismatch" };
  if (input.joinFailure === "invitation_invalid") return { kind: "invalid" };
  if (input.details === undefined) return { kind: "loading" };
  switch (input.details.status) {
    case "ok":
      return { kind: "ready", teamName: input.details.teamName };
    case "mismatch":
      return { kind: "mismatch" };
    case "invalid":
      return { kind: "invalid" };
    default:
      return { kind: "ready", teamName: null };
  }
}

/**
 * Accept the invitation and open the team. Returns null on success, or the
 * failed request's error for the page to show.
 */
export async function acceptAndOpenTeam(
  code: string,
  dependencies: {
    readonly accept: (code: string) => Promise<{ teamId: string }>;
    readonly afterJoin: () => Promise<void>;
    readonly navigate: (href: string) => void;
  },
): Promise<unknown> {
  try {
    const { teamId } = await dependencies.accept(code);
    await dependencies.afterJoin();
    dependencies.navigate(`/dashboard/teams/${encodeURIComponent(teamId)}`);
    return null;
  } catch (error) {
    return error;
  }
}

export function AcceptInvite({ code, viewerEmail }: { readonly code: string; readonly viewerEmail: string | null }) {
  const locale = useLocale();
  const router = useRouter();
  const stackApp = useStackApp();
  const queryClient = useQueryClient();
  const errorText = useTeamErrorText();
  const [pending, setPending] = useState(false);
  const [joinFailure, setJoinFailure] = useState<string | null>(null);
  const [joinError, setJoinError] = useState<string | null>(null);

  const details = useQuery({
    queryKey: ["team-invitation-details", code],
    queryFn: async () => invitationDetailsFromResult(await stackApp.getTeamInvitationDetails(code)),
    enabled: code.length > 0,
    retry: false,
    // A preview failure must not block joining; fall back to "unknown".
    throwOnError: false,
  });

  const join = async () => {
    setPending(true);
    setJoinError(null);
    const error = await acceptAndOpenTeam(code, {
      accept: teamApi.accept,
      afterJoin: () => invalidateTeamScope(queryClient),
      navigate: (href) => router.push(href),
    });
    if (error === null) return;
    const failure = teamErrorCode(error);
    setJoinFailure(failure);
    if (failure !== "email_mismatch" && failure !== "invitation_invalid") setJoinError(errorText(error));
    setPending(false);
  };

  return (
    <InviteResponseCard
      state={acceptInviteState({
        code,
        details: details.isError ? { status: "unknown" } : details.data,
        joinFailure,
      })}
      viewerEmail={viewerEmail}
      pending={pending}
      error={joinError}
      onJoin={() => void join()}
      returnPath={acceptReturnPath(code)}
      locale={locale}
    />
  );
}
