# Lane: integrations

## Active streams
- Google integrations and CASA (spec-coverage P16) and integrations backend hygiene (P24): integrations lead. Plan plans/cmux-next/integrations-plan.md; Lawrence step files are private (worker scratch). Signer: Lawrence.

## Landed
- 2026-10-03 (this push) backend: G5 disconnect revokes the grant at the provider. ConnectionDO side table `pending_revocations` (sealed copy kept only until the provider confirms, at most 24 h, alarm retries with backoff); `ProviderImpl.revoke` (Google: oauth2 revoke of the refresh token). A refused activation also revokes. (integrations lead)
- 2026-10-03 0b18767b5bd backend/protocol: providers `gmail` and `google_calendar` (IntegrationProvider literal widened; one Google OAuth client; PKCE S256 per attempt from an HKDF key of the KEK). Ten cloud ops in packages/protocol/src/google-ops.ts: `calendar.calendars.list|events.list|event.create|event.respond`, `mail.send|search|get|thread.get|threads.peek|modify`. Env `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_RESTRICTED_SCOPES` (testing|internal|verified; production honors only verified). Gmail connections are always private. Shared provider types moved to integrations/provider-core.ts; `ProviderImpl` gains `refuseScopes`, `scopesFor`, a `connection` and `state` argument to `authorizeUrl`/`complete`, and a function form of `defaultScopes`. Pending: regenerate cmux-tui/crates/cmux-app-host/generated/* in a cmux-tui window (base was already stale). (integrations lead)
