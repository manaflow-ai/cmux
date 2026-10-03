# Backend lead: stage B resume note (parked 2026-10-02, Claude capacity 2/28)

Resume after the Oct 4 reset. Branch for stage B code: `backend-home-routes` (off feat-cmux-next; no code yet).

## In flight when parked

- https://github.com/manaflow-ai/cmux/pull/16861 (Home catalog): base merged in, generated catalog and client regenerated (106 ops), protocol index exports `ops-home.ts` and `ops-home-schemas.ts`. Self-reviewed (owners, risks, principals). Next: merge when the CI `test` check passes.
- https://github.com/manaflow-ai/cmux/pull/16859 (0006_home schema + projections): base merged in (3c6821bb240), migration lint and projection tests pass, label `backend:apply-migrations` added (applies to staging and production before merge). Next: confirm `apply-staging`, `apply-production` and `backend migrations applied` pass, then merge. Tables hold no raw address, secret or token hash; `home_message_search` holds message text for home.search (by design).

## Stage B order (approved by the coordinator)

1. Home HTTP routes: `ownerRoute` cases for cloud:ConversationDO (keyed by `params.id`/conversation, stripped from params), cloud:MuxDO (agent, principal through withGrantClasses for install_kind), cloud:planetscale (home.search through a read-only Hyperdrive); inbox ops to UserDO `submitInbox`/`readInbox`. Worker derivations: conversation id, invite_id, address id (HMAC HOME_ADDRESS_KEY), token_hash, proof. Endpoints `GET /v1/invites/card/<code>` (open invite only, never user-to-user DM; the staging card waits on this), `POST /v1/invites/preview`, invite.accept with acceptLocked; `/v1/wire/conv/<id>` (E5); DM peer lookup (Q2); approval rules.
2. UserDO: delegate `user.text_confirm.*` and `user.presence_key.*` to home-core `reduceUserConfirm` (env user, installActive, installKind, chiefs, appIdHash, locale); presence-key route (macOS: install-key signature; iOS: App Attest attestation, then submitSystem `user.presence_key.register`); `install.revoke` and `install.revoke_by_team` also commit `user.presence_key.revoke`.
3. MuxDO route with install_kind; confirm streams `mux:<agent>` and `user:<user>` (system:mux:<agent>, system:user:<user>); conversation-search `{query, limit 1-100}` in POST /v1/read; one `mux.text_confirm.migrate` pass per chief after re-pushing team/MDM locks (minimum-only semantics).
4. Lane 15 security follow-ups: per-account phone link limits (5/day, 2 numbers/day) with one uniform answer; link page rules (home-messaging.md section 19); SendBlue fetch-by-handle before acting on a webhook; relink notice to the previous account.
5. Stage-A P3 leftovers: readInbox checks installActive; inbox prune slack; bind entity only after auth.

Stage C (after B): MailerDO (wrangler tag v8) and the mail path for `mail.security_notice`; FeedDO accepts feed.post notices from UserDO; AddressDO sends (vCard first, text after SENT/DELIVERED, allow list fail-closed, HOME_INVITES_SEND kill switch, every staging send logged and reported).

Other open items: shared teams after stage C (plan in enterprise.md); verify the OIDC callback's Stack server calls on staging the next time auth changes; Effect 4.0.0 bump after 2026-10-08; integrations gateway after stage C.
