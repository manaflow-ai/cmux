# First-contact SSH follow-ups (#35701)

The candidate probe shares enrollment's SSH failure classification. An unknown host key
leaves the existing optional `ssh_ok` field absent, so Add Machine can select it and the
explicit Add action can record the first key. The background probe forces strict checking
and disables host-key updates. Changed and revoked keys stay rejected; revoked-key
recovery asks the owner to replace the key rather than suggesting first-contact acceptance.
Both `known_hosts`'s `@revoked` marker and `RevokedHostKeys` file diagnostics use that recovery.
Probes and first-contact checks preserve error diagnostics under quiet SSH configurations.
Only positive unknown-key diagnostics permit first contact; generic verification failures and
invalid revocation files remain rejected, with configuration-specific recovery. The user's
`CheckHostIP` policy remains intact and may add an IP alias for an already trusted key.

This runs only in the bounded candidate CLI probe and enrollment reach check. The existing
32-host limit and eight concurrent probes are unchanged; no daemon request path, timer,
shared state or per-session work is added.

Detectors: `first_contact_unknown_candidates_remain_unverified_and_pickable`,
`first_contact_revoked_key_recovery_never_suggests_acceptance_or_removal`, and
`first_contact_real_ssh_records_only_unknown_keys`. The last uses temporary keys and
an inetd-mode SSH server on a private pipe, checking stored-key bytes after every state.
