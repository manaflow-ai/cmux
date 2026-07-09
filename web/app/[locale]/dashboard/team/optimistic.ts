import type { TeamSummaryDto } from "@/services/team/invites";

type OptimisticMutation<T> = {
  readonly requestId: string;
  readonly previous: T;
  readonly next: T;
};

export function applyOptimisticRevoke(
  state: TeamSummaryDto,
  invitationId: string,
  requestId: string,
): OptimisticMutation<TeamSummaryDto> {
  return {
    requestId,
    previous: state,
    next: {
      ...state,
      invitations: state.invitations.filter((invitation) => invitation.id !== invitationId),
    },
  };
}
