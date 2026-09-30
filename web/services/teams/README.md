# Team membership webhook

`membershipWebhook.ts` verifies Stack/Svix `POST /api/webhooks/stack` requests
using `STACK_TEAM_WEBHOOK_SECRET`. The secret must use Stack's `whsec_` format.
The route must pass a reconciliation function to
`createStackMembershipWebhookHandler`; reconciliation receives
`(teamId, userId, eventId)` so callers can make processing idempotent.
