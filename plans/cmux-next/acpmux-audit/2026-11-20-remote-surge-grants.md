# Remote surge grants

The local subscription index and `Hub::resolve` deliberately contain local sessions only.
Remote owners use an explicit recipient grant to `HOST/UUID`, resolved through the configured
peer; display names and model output never select the destination.

The peer daemon answers a single-thread subscription probe through `_acpmux/inbox_subscriptions`
with `sessionId` and `threadId`. This requires peer-daemon credentials, returns only the named
thread's opt-in, and does not authorize enumeration or mutations. Grant writes still require
the recipient's own agent or the person.

Each outbox attempt and redelivery rechecks the recipient's journal grant and the remote
subscription. The receiver checks its subscription again before accepting the digest.
Asynchronous mesh and SSH fallbacks are excluded from this path because those carriers cannot
recheck recipient revocation before forwarding. An unreachable peer leaves the digest owed.

Detectors: `remote_surge_requires_subscription_grant_and_verified_peer` uses two isolated hubs
and a real WebSocket authenticated with listener and peer tokens; it covers duplicate delivery,
revocation and owner withdrawal. `subscription_rpc_rejects_unrelated_sessions_and_unverified_peer_probes`
checks method access, and `subscription_and_grant_survive_disk_restart_and_revocation` reopens
the journal twice. A sender cannot retract bytes already accepted by the remote daemon.

Authenticated digests retain peer attribution but bypass surge holding, just as local digests
do. `surge_digests_with_peer_attribution_are_not_held_again` detects recursive holding of the
receiver's actionable summary.
