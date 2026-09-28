"use client";

import { useQuery } from "@tanstack/react-query";
import { useLocale } from "next-intl";
import { useState } from "react";
import { useRouter } from "@/i18n/navigation";
import { InviteResponseCard, type InviteResponseState } from "@/dashboard-app/screens/teams/invite-response";
import { type JoinLinkInfo, teamApi, teamErrorCode } from "@/dashboard-app/queries/teams";
import { useTeamErrorText } from "@/dashboard-app/screens/teams/team-ui";

const INVALID_LINK_CODES = new Set(["link_invalid", "link_not_found", "invitation_invalid", "http_404", "http_410"]);

export function joinInviteState(input: {
  readonly info: JoinLinkInfo | undefined;
  readonly infoError: unknown;
  readonly joinFailure: string | null;
}): InviteResponseState {
  if (input.joinFailure && INVALID_LINK_CODES.has(input.joinFailure)) return { kind: "invalid" };
  if (input.infoError) {
    // An outage should not look like a dead link: offer Join and let the
    // POST report the real failure.
    return INVALID_LINK_CODES.has(teamErrorCode(input.infoError)) ? { kind: "invalid" } : { kind: "ready", teamName: null };
  }
  if (!input.info) return { kind: "loading" };
  return input.info.alreadyMember
    ? { kind: "alreadyMember", teamName: input.info.teamDisplayName }
    : { kind: "ready", teamName: input.info.teamDisplayName };
}

export function JoinInvite({ token, viewerEmail }: { readonly token: string; readonly viewerEmail: string | null }) {
  const locale = useLocale();
  const router = useRouter();
  const errorText = useTeamErrorText();
  const [pending, setPending] = useState(false);
  const [joinFailure, setJoinFailure] = useState<string | null>(null);
  const [joinError, setJoinError] = useState<string | null>(null);
  const info = useQuery({
    queryKey: ["team-join-link", token],
    queryFn: ({ signal }) => teamApi.joinInfo(token, signal),
    retry: false,
  });

  const join = async () => {
    setPending(true);
    setJoinError(null);
    try {
      // Joining an already-joined team is idempotent and returns its id.
      const { teamId } = await teamApi.join(token);
      router.push(`/dashboard/teams/${encodeURIComponent(teamId)}`);
    } catch (error) {
      const failure = teamErrorCode(error);
      setJoinFailure(failure);
      if (!INVALID_LINK_CODES.has(failure)) setJoinError(errorText(error));
      setPending(false);
    }
  };

  return (
    <InviteResponseCard
      state={joinInviteState({ info: info.data, infoError: info.error, joinFailure })}
      viewerEmail={viewerEmail}
      pending={pending}
      error={joinError}
      onJoin={() => void join()}
      returnPath={`/join/${encodeURIComponent(token)}`}
      locale={locale}
    />
  );
}
