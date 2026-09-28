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
- Seats: soft. Joining over the paid seat count is allowed; admins see a
  nudge to add seats. PR #11352 (use-time seat demotion) is not merged here.
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

- `POST /api/teams` `{ displayName }` -> `201 { team: { id, displayName } }`.
  Creator gets `team_admin`, team becomes selected.
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
