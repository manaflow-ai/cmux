# Team settings, invites, and per-team billing

Replaces Hexclave `<AccountSettings />` with cmux-owned settings, adds team
invites (per-email and reusable links), and makes every team upgradable on
its own.

## Decisions

- Invite links: one reusable link per request, admin-only creation, optional
  expiry and max uses, revocable. Links grant `member` only; admin is granted
  by email invite or by promotion after join, so a leaked link never hands out
  admin.
- Roles: `admin` (Stack `team_admin`) and `member`. Admins invite, remove,
  change roles, rename, manage billing, delete. A team always keeps one admin.
- Seats: the Team subscription quantity follows the member count, $60 per
  member. Joining is never blocked. Membership changes are billable facts:
  invitation accept, link join, removal, and leave mark the team dirty in
  `team_seat_reconciles`; sending an invitation does not, and pending
  invitations cost nothing. A reconciler (`services/billing/teamSeats.ts`)
  counts current Stack members, and when the Stripe quantity differs updates
  it with `create_prorations`, inline after the response and from the
  `/api/cron/team-seats` sweep. The membership write never waits on billing.
  Team subscription create/update webhooks also mark the team dirty, so an
  external quantity edit is reconciled back to the member count. The Team
  Billing Portal uses a dedicated configuration that disables quantity edits
  while preserving cancellation, invoices, and payment-method updates. Pro and
  Max personal teams keep the fixed 3-member cap in `services/teams/seats.ts`
  and have no per-seat quantity; free teams are ignored. PR #11352 (use-time
  seat demotion) is not merged here.
- Personal plans stay user-scoped. The synthetic personal entry (`id ===
  user.id`) routes to Pro/Max checkout, real teams to Team checkout.

## Routes (web)

Account settings, all client components on the Hexclave client SDK:

- `/dashboard/settings` (profile), `/dashboard/settings/auth`,
  `/dashboard/settings/notifications`, `/dashboard/settings/sessions`,
  `/dashboard/settings/api-keys`, `/dashboard/settings/account`.
- Payments lives on `/dashboard/billing` (Stripe is ours, not Hexclave
  payments).

Teams:

- `/dashboard/teams` list, `/dashboard/teams/new` create then choose Free or
  upgrade, `/dashboard/teams/[teamId]` general,
  `/dashboard/teams/[teamId]/members`, `/dashboard/teams/[teamId]/api-keys`,
  `/dashboard/teams/[teamId]/billing`.
- `/dashboard/team/accept?code=` accepts a Stack email invitation and applies
  the stored role. `/join/[token]` redeems a reusable link.
- `/dashboard/team` redirects: `#team-<id>` to `/dashboard/teams/<id>`,
  `#team-creation` to `/dashboard/teams/new`, otherwise `/dashboard/settings`.
  Stack `urls.accountSettings` points at `/dashboard/settings`.

## Team API contract

All JSON, cookie or native auth via `verifyRequest`, browser-origin check on
mutations, rate limited on invite, link, and create. Errors are
`{ error: { code, message } }` with 400/401/403/404/409/429/503.

```ts
type TeamRole = "admin" | "member";
type TeamViewerPermissions = {
  updateTeam: boolean; deleteTeam: boolean; inviteMembers: boolean;
  readMembers: boolean; removeMembers: boolean; manageApiKeys: boolean;
  manageBilling: boolean;
};
type TeamMember = { userId: string; displayName: string | null;
  email: string | null; profileImageUrl: string | null; role: TeamRole;
  isViewer: boolean };
type TeamInvitation = { id: string; email: string | null; role: TeamRole;
  expiresAt: string };
type TeamInviteLink = { id: string; role: "member"; createdAt: string;
  createdByUserId: string; expiresAt: string | null; maxUses: number | null;
  useCount: number };
type TeamBillingSummary = { planId: string | null; seats: number | null;
  memberCount: number; hasActiveSubscription: boolean };
type TeamDetail = { team: { id: string; displayName: string;
  profileImageUrl: string | null }; viewer: { userId: string; role: TeamRole;
  permissions: TeamViewerPermissions }; members: TeamMember[];
  invitations: TeamInvitation[]; links: TeamInviteLink[];
  billing: TeamBillingSummary };
```

- `GET /api/teams` -> `200 { teams: TeamListing[], selectedTeamId: string |
  null }`, where `TeamListing = { id, displayName, profileImageUrl: string |
  null, role: TeamRole, permissions: TeamViewerPermissions }`. Membership is
  read fresh from Hexclave (one paged read of the user's teams), then each
  team's grants as `requireTeamAccess` reads them, at most 4 at a time. A team
  deleted during the read is left out; any other Hexclave failure is a 503
  with `retry-after`, never a guessed role. `selectedTeamId` is null unless
  the selected team is in `teams`. The macOS and iOS apps use this to show
  roles and to enable rename and delete only for admins.
- `POST /api/teams` `{ displayName }` -> `201 { team: { id, displayName } }`.
  Creator gets `team_admin`, team becomes selected. Every path that creates a
  team must grant the creator `team_admin` and delete the team when that grant
  fails (`grantTeamAdmin` here; `createTeam` in the iOS Worker
  `cmux-next-ios/backend`). Teams created before the Worker did this are found
  by `web/scripts/backfill-team-admins.ts`.
- `GET /api/teams/[teamId]` -> `TeamDetail` (invitations and links empty for
  non-admins).
- `PATCH /api/teams/[teamId]` `{ displayName?, profileImageUrl? }` (admin).
- `DELETE /api/teams/[teamId]` (admin). 409 `team_has_active_subscription`
  while a Team subscription is active.
- `POST /api/teams/[teamId]/invitations` `{ emails: string[] (1-20), role }`
  -> `{ invitations: TeamInvitation[], failed: { email, code }[] }`.
- `POST /api/teams/[teamId]/invitations/[id]/resend` -> `{ invitation }`.
- `DELETE /api/teams/[teamId]/invitations/[id]`.
- `POST /api/teams/[teamId]/links` `{ expiresInDays: 1|7|30|null,
  maxUses: number|null }` -> `{ link: TeamInviteLink, url: string }`. The raw
  token only appears in this response.
- `DELETE /api/teams/[teamId]/links/[id]`.
- `PATCH /api/teams/[teamId]/members/[userId]` `{ role }` (admin, keeps one
  admin).
- `DELETE /api/teams/[teamId]/members/[userId]` (admin, or self to leave;
  keeps one admin).
- `GET /api/teams/join/[token]` -> `{ teamDisplayName, alreadyMember }`;
  `POST` same path joins -> `{ teamId }`.
- `POST /api/teams/accept` `{ code }` -> `{ teamId }`; 409
  `email_mismatch`, 410 `invitation_invalid`.

## Billing contract

- `GET /api/billing/checkout?plan=team&teamId=` and
  `POST {plan:"team", teamId}`: explicit team, admin only. Without `teamId`
  the legacy implicit resolution stays for old macOS clients.
- `GET /api/billing/portal?scope=team&teamId=` and
  `POST /api/billing/subscription` with `teamId`: explicit, admin only.
- `GET /api/billing/plan?teamId=` returns that team's status.
- `GET /api/subrouter/teams` adds per team `planId`, `seats`, `role`,
  `canManageBilling`.
- `/dashboard/billing` shows the dashboard-selected team.
