/** Wire shape of `GET /api/dashboard/session`. Shared by the route and the SPA. */
export type DashboardSessionUser = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  readonly profileImageUrl: string | null;
  readonly selectedTeamId: string | null;
};

export type DashboardSessionResponse = {
  readonly user: DashboardSessionUser;
  readonly flags: { readonly vaultEnabled: boolean };
};
