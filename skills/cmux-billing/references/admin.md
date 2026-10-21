# Staff admin routes

Lookup detail for [../SKILL.md](../SKILL.md). The staff-only `/api/admin/*`
routes let admins search users, teams, and emails and change their plan.

## Who is an admin

A verified `cmux.com`, `manaflow.ai`, or `manaflow.com` email, or a verified
email with an active `admin_members` row. `services/admin/routeAuth.ts`
`requireAdmin` is the gate; the domain check is in `services/admin/access.ts`.
Non-admins get 403. The admin UI is not part of this repository and there is no
admin page on cmux.com.

## Routes

| Route | Does |
| --- | --- |
| `/api/admin/users` | grant or remove the user `cmuxVmPlan` override |
| `/api/admin/teams` | grant or remove a team override of `team` |
| `/api/admin/email-grants` | grant Pro to an email with no account yet; stored in `admin_plan_grants` and applied by the after-sign-in callback once the mailbox is verified |
| `/api/admin/subscriptions` | downgrade a paying customer by cancelling the Stripe subscription at period end (same service as the self-serve form) |
| `members`, `audit`, `pro-users` | admin invites, the audit log, and the Pro roster |

`services/admin/proGrants.ts` writes under the account-mutation lease and
records `serverMetadata.cmuxAdminPlanGrant` (who, when, which plan).

The `admin_plan_grants` migration is an operator step; until it runs, pending
email grants report 503 and search omits them.
