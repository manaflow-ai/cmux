# Integrations lead plan: Google integrations, CASA steps 1 to 5, backend hygiene

Status: draft 1, 2026-10-03. Owner: the integrations lead (spec-coverage P16 and P24). Signer for Google and the CASA lab: Lawrence (B-ALL item 23, S1).
Spec: spec/integrations.md (draft 3, D14, S1, S2, S3), research/google-oauth-casa.md, plans/cmux-next/feed.md 11.2 and 11.3.

## 1. What exists (feat-cmux-next, 2026-10-03)

- `ConnectionDO` (one per owner team): connection records through the op protocol, sealed credentials in a side table (AES-256-GCM envelope, KEK = `INTEGRATIONS_KEK` Worker secret, AAD = connection, owner, provider, generation), an external-effect ledger (replay, `mutation.indeterminate`), single-flight token refresh, `ingest` to `SchedulerDO.deliverEvent`.
- Providers: GitHub App, Linear, Slack bot (`backend/apps/api/src/integrations/providers.ts`). Webhooks `POST /v1/hooks/{github,slack,linear}` through `AccountIndexDO`.
- `TeamIntegrationPolicy` (projection of TeamDO's TeamPolicy), `libs/integrations-core` (ingestion and per-tool policy, MIT), lane 3's integrations app (draft 17055).
- Missing: every Google provider, push channels and watches, Pub/Sub receiver, KMS, rate limits, gateway approvals, the event log, the feed poster, `installation_repositories` refresh.

## 2. Code versus Lawrence

| Work | Who | Where |
| --- | --- | --- |
| Google providers, ops, push receiver, renewals, deletion, KMS client, rate limits, approvals, event log, feed poster | integrations lead (code, workerd tests, staging only) | backend/apps/api, backend/packages/protocol |
| New Worker routes, DO tags, Queue or R2 bindings, rate-limit namespaces, secrets on staging | backend lead (via main) | wrangler.jsonc, deploy |
| Google Cloud projects, consent screen, brand verification, OAuth clients with real secrets, Pub/Sub topic and push subscription, scope submissions, demo video upload, CASA lab purchase and signing | Lawrence (exact step files prepared by the lead) | `.cmux-scratch/nx-worker/integrations/` (private) |
| Privacy policy, Limited Use statement, data deletion help page on cmux.com | web owner lands the text the lead drafts; Lawrence approves | web/ (a main merge deploys production) |
| AWS KMS key and the Worker's IAM principal | Lawrence or the infra owner (step file), money: about 1 USD per key per month plus requests | AWS console |

Nothing in this plan deploys to production. Production gets Google secrets only after verification, on Lawrence's word.

## 3. Slice order (each slice: workerd tests, typecheck, review subagent for security, OAuth and token storage)

G1. Google provider core. Two providers on one OAuth client: `google_calendar` and `gmail` (separate consent and separate connections, so a Calendar user never sees a Gmail screen and the team policy can allow one without the other). Web server flow with `access_type=offline`, `prompt=consent`, PKCE (S256), `include_granted_scopes=false`. Account from the ID token (`sub`, verified email). Account key `google:<sub>` for both; a routing alias `gmail:email:<lowercased address>` in `AccountIndexDO` because Gmail push carries only the address. Refresh through the existing single flight; `invalid_grant` flips the connection to `needs_reauth`. Code in `integrations/google.ts` (providers.ts stays under the 500-line rule). Ops: `calendar.events.list`, `calendar.event.create` (send-external when it has attendees), `calendar.event.respond` (send-external), `mail.send` (send-external), `mail.search`, `mail.get`, `mail.thread.get`, `mail.threads.peek` (feed rows, ids in, minimal headers out, never stored), `mail.modify {labels, archive}` (mutate-own). Restricted Gmail scopes (`gmail.readonly`, `gmail.modify`) are refused by the Worker unless the deployment sets `GOOGLE_RESTRICTED_SCOPES=testing|internal|verified`; production stays unset until the CASA Letter of Validation.

G2. Calendar push channels. `events.watch` per connection with our channel id and a per-channel random token (stored sealed), push to `POST /v1/hooks/google/calendar` (new route, backend lead). The notification has no content; the receiver routes by channel id to the connection and the ConnectionDO pulls changes with the stored `syncToken`. Emits `calendar.event.changed {connection, calendar, event_id}` (ids only).

G3. Gmail push (S2). Pub/Sub push to `POST /v1/hooks/google/pubsub` (new route): verify the Google OIDC JWT (RS256, JWKS from Google, audience = our endpoint, `email` = the push service account, `email_verified`), decode `{emailAddress, historyId}`, route by `gmail:email:<address>`. The ConnectionDO calls `history.list` from its stored cursor and emits one `mail.message.received {connection, message_id, thread_id, labels}` per new message to `SchedulerDO.deliverEvent`. Stored per connection: watch expiry, history id cursor, nothing else. Ack after the cursor commit; a duplicate push is a no-op because the cursor already moved.

G4. Renewals and the fallback check. The ConnectionDO alarm renews Gmail watches daily (Google's advice; hard limit 7 days) and Calendar channels before expiry. Three failed renewals flip the connection to `error` and post a feed notice. While a watch is unhealthy the same alarm runs `history.list` from the cursor every 15 minutes (server-side fallback, allowed by S2) and stops when push is healthy again.

G5. Deletion. `integration.revoke` already deletes the credential. Add: stop the Gmail watch and Calendar channels, revoke the Google token (`oauth2.googleapis.com/revoke`), delete cursors, channel tokens and every stored id for that connection, drop the routing alias. Account deletion calls the same path for every connection the user created. This is CASA evidence (deletion on request).

G6. KMS wrap (P24). A `KeyWrapper` interface with two implementations: the current KEK and AWS KMS (`Encrypt`/`Decrypt` of the 32-byte data key with encryption context = connection, owner, provider, generation; SigV4 signed with Web Crypto HMAC, so it runs in workerd). Stored shape gains `kid` (`kek:v1` or `kms:<key arn>`); old rows stay readable and are re-wrapped on the next seal. Tests: workerd, a fake KMS endpoint, and a recorded SigV4 vector.

G7. Rate limits (P24). Per-connection token buckets in the ConnectionDO keyed by provider limits (Gmail 250 quota units per user per second, Calendar per-user limits, Slack tier 3, GitHub installation limits). A 429 or `Retry-After` answers `provider.rate_limited` with `retry_after_ms`, retryable, and the Workflow step backs off durably.

G8. Gateway approvals (P24, D13). A provider op with risk `send-external`, `money` or `destructive` from a non-session principal (agent, automation run, app) is not run; the ConnectionDO posts an `approve` feed request (poster kind `integration`) with the exact op and parameters digest and answers `approval.pending {request}`. The user's answer runs the op once under a key derived from the request id. A run triggered by external content (mail, webhook) never gets a standing grant for these classes. Needs a FeedDO RPC for system posters (lane 9).

G9. Feed poster (P24). GitHub `pull_request.review_requested`, failing `check_suite` and similar events post one notice per item (`dedupe_key = gh:<repo>:pr:<n>:review`) to the affected user's FeedDO and cancel it when resolved. Gmail new mail posts ids-only `mail` notices (feed.md 11.2). Coordinate with lane 9 (feed lead).

G10. `installation_repositories` refresh (P24). Added and removed repositories update the linked repository list of each connection on that installation under `linking_user_repos` scope: removals apply at once; additions apply only when the linking user can still access them (a check with the stored user grant is not possible after linking, so additions wait for a re-link; recorded as a known limit).

G11. Ingestion pipeline remainder (P24). Durable event log with dedupe on (connection, provider delivery id) before the 200 ack; non-email payloads in R2 encrypted per owner with 30-day retention; `event.search` and `event.get`; email rows hold ids only. Needs an R2 bucket binding and possibly a Queue (backend lead).

G12. End-to-end test (P16 done-when). In workerd: a signed Pub/Sub push for a connected test mailbox fires an automation, the run input holds only ids, and a scan of every DO table and the projection finds no subject, sender, snippet or body.

## 4. CASA timeline (steps 1 to 5 now; 6 to 8 after)

| Week | Step | Who |
| --- | --- | --- |
| 0 | 1. Create `cmux-integrations` (production, verified) and `cmux-integrations-dev` (Testing, staging and development) projects; contacts, two owners | Lawrence (step file 01) |
| 0 to 2 | 2. Brand verification: home page, privacy policy with the Limited Use statement, deletion help page on cmux.com; authorized domain; logo | web owner lands drafts; Lawrence submits (step file 02) |
| 1 to 4 | 3. Sensitive-scope verification: Calendar scopes and `gmail.send`, scope justifications, demo video | lead drafts; Lawrence records and submits (step file 03) |
| 0 to 4 | 4. Dogfood Gmail read: Internal app in the manaflow Workspace, or the dev project in Testing with named test users (7-day reauth) | Lawrence creates; lead wires staging (step file 04) |
| 2 to 6 | 5. CASA controls built and evidenced (G1 to G12, the controls matrix) | lead (step file 05 is the evidence index) |
| 6 to 12 | 6. Submit restricted scopes; 7. lab assessment (Google assigns the level; about 675 to 1,800 USD per year at the lower level, about 4,500 at the higher); 8. enable Gmail push and server-side Gmail automations in production | Lawrence signs and pays; lead fixes findings |

Yearly recertification: a calendar entry 30 days before the Letter of Assessment date, owned by the integrations lead, signed by Lawrence.

## 5. Decisions for main (recommendations)

1. Two providers (`gmail`, `google_calendar`) on one OAuth client. RECOMMEND: yes, because consent, policy and verification stay per product.
2. Watch and channel renewal owner: the spec names SchedulerDO. RECOMMEND the ConnectionDO alarm, because the token, the cursor and the single-flight refresh are there and a second owner would need the token. Spec proposal after G4 lands.
3. Two Google Cloud projects (production verified, dev in Testing). RECOMMEND: yes, because the unverified 100-user cap is lifetime per project and a staging scope test must never touch the verified project.
4. Gmail connections are always private (no "Share with team"). RECOMMEND: yes, because a shared mailbox token lets teammates' agents read one person's mail, which Limited Use and CASA reviewers flag.
5. KMS: AWS KMS with an IAM user whose access keys are Worker secrets (Workers cannot use OIDC federation). RECOMMEND: yes, with a key policy that allows only Encrypt and Decrypt with our encryption context keys; the residual risk is a long-lived access key in a Worker secret.
6. Feed mail items ids-only (feed.md 11.2 recommendation). RECOMMEND: yes; it is the S2 rule.

## 6. Risks

- Google may assign the higher assurance level; the cost rises and stays.
- Testing-mode tokens expire after 7 days, so staging Gmail watches break weekly; staging alerts must treat that as expected.
- Gmail push needs the org policy to allow the publisher grant to `gmail-api-push@system.gserviceaccount.com` (domain-restricted sharing may block it).
- The approval slice depends on a FeedDO system-poster RPC; until it lands, agent and automation calls of send-external ops are refused, not queued.
