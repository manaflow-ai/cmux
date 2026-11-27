# Notice to PL-acpmux: the asksBeforeTools claim and the launch digest (2026-11-09)

Owner W5-L, lead decisions of 2026-11-09. Read with #39648 and its follow-up PR (branch
`acpmux-claim-digest-remote`).

## What changed
- #39648: an ACP agent's `agentCapabilities._meta.acpmux.asksBeforeTools` claim holds a narrow
  policy only when acpmux started the agent from a harness entry of its own config
  (`Config::profile`), and only while the entry's `launch_digest` (argv and env) equals the one the
  agent started from (`policy_mode.rs` `claim_distrust`: `not_started_here`, `not_a_config_entry`,
  `entry_changed`). Each claim is logged as the session event `asks_before_tools_claim
  {harness, trusted, reason}`. An import, and a start with a different launch, drop the copied
  `agent_capabilities`. `require_enforced` takes `&Config`.
- Follow-up: a remote chat records the digest of its entry as the entry is written
  (`Resolved::launch_digest`, taken before `admit_remote_profile` resolves the program to its
  canonical path). `claim_distrust` compares digests only and reads no file, and a catalog reload
  that changes nothing no longer marks a remote chat `respawn_pending` (`profile_respawn.rs`).

## Open items (not fixed)
- The digest is taken before `${cwd}`/`${home}` expansion and before the launcher is resolved. An
  entry with `${cwd}` in argv or `PATH`, or a relative or folder-resolved program (`npx`), can run
  code that the chat folder chooses while its claim is still believed.
- An argv pin that skips approvals (`--yolo`, `--dangerously-skip-permissions`) does not cancel the
  claim. Only a reported full-access mode does (`asks_before_tools`).
- The preset env and the family or profile `defaults` env are outside the digest. A change to them
  after the start does not give `entry_changed`. Only a person can set them.
- A pooled agent taken after its entry changed is recorded with the new digest
  (`pool_take_claimed_for` does not compare the pooled launch).
- A folder profile whose name a config entry with the same argv and env takes later is believed
  for an agent host started from the folder profile. Recording the origin (config or folder) in
  the session meta would close it.
