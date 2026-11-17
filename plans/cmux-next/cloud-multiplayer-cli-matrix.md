# Cloud multiplayer: CLI verb matrix

Every `cmux` verb the `cloud-multiplayer` branch adds or changes against `git merge-base HEAD origin/feat-cmux-next`
(e5b7c867c5). Rust tests are in `cmux-tui/crates/cmux-tui/src` unless a path says otherwise. Scenarios are
`scripts/cmux-next/cloud-selftest/scenarios.ts`; `cloud-selftest.test.ts` fails when one names a verb the Rust sources
do not offer. Route: **API** runs headless with `CMUX_CLOUD_API_URL`, `CMUX_CLOUD_ACCESS_TOKEN` and `CMUX_CLOUD_TEAM`;
**App** answers through a tagged app's socket (`CMUX_TAG`, its `bin/cmux`); **Link** dials through this computer's
link; **Internal** is the app's own plumbing.

| Command (`--json`) | Answer | Error codes | Rust tests | Scenario | Route |
| --- | --- | --- | --- | --- | --- |
| `cloud team-keys status [--team T]` | `{team, can_manage, agents: [{agent, set, kind, generation, updated_at, updated_by, hint}]}` | `usage.invalid` (exit 2), `auth.unauthenticated`, `team.not_member`, `auth.forbidden`, `cloud.unreachable`, `cloud.client.unreadable` | `cli/cloud_team_keys.rs`: `parses_status_set_and_remove_and_keeps_the_key_off_argv`, `resolves_the_team_from_the_flag_or_the_environment` | `team_keys.shared_path`, `cli.usage_errors` | API |
| `cloud team-keys set claude\|codex [--kind api_key\|oauth] [--secret-file P] [--idempotency-key K]` | the agent's state, plus `replayed: true` for a replay | the above, plus `validation.invalid`, `team_agent_key.not_configured`, `revision.conflict`, `idempotency.conflict` | same file: `a_replayed_set_says_so_and_a_refusal_keeps_its_code`, `a_secret_file_is_read_without_its_trailing_line_break` | `team_keys.shared_path`, `cli.usage_errors` | API |
| `cloud team-keys remove claude\|codex` | `{agent, removed}` | as for set | `parses_status_set_and_remove_and_keeps_the_key_off_argv` | `team_keys.shared_path` | API |
| `cloud machine-auth --machine VM` | `{machine_id, ok, cloud_vm, edge_host, model_plane, daemon, agents: {claude, codex}, credential_env, login_files, holds_credential, managed_route_files}`; exit 1 when not `ok` | `usage.invalid` (2), `machine_auth.unsupported`, `machine_auth.invalid_reply`, exec codes (`vm_not_running`, `vm_not_found`) | `cli/cloud_machine_auth.rs`: `it_parses_the_machine`, `it_returns_the_machine_report_with_its_id`, `a_caller_with_its_own_credential_asks_the_machine_without_the_app`, `an_old_machine_or_an_exec_refusal_is_typed`; `acpmux/src/cli/machine_auth.rs`: 3 tests | `vm.login_free`, `cli.usage_errors` | App (`cloud exec`), or API with a token (`machine access exec`) |
| `cmux-tui acp --json machine-auth` (on the machine) | the report above, without `machine_id` | none: the verdict is in `ok` | `acpmux/src/cli/machine_auth.rs`: `a_bare_daemon_env_reports_the_machine_route`, `a_login_file_or_a_real_key_is_reported_by_name_only`, `no_daemon_no_file_or_another_endpoint_is_not_ok` | through `vm.login_free` | Internal |
| `inference gateway status [--personal] [--team T]` | `{ok, scope: team\|personal, gateway: {mode, machine, online, kind, connected_at}}` | `cli.invalid_args` (2), `auth.no_token`, `api.unreachable`, `api.bad_answer`, the API's (`auth.forbidden`) | `cli/inference_gateway_admin.rs`: `parses_status_mode_and_route`, `scopes_the_status_and_keeps_api_error_codes` | `gateway.admin`, `gateway.admin_personal`, `gateway.offline_reconnect`, `gateway.route_order` | API |
| `inference gateway mode gateway\|off [--personal] [--gateway-machine VM \| --no-gateway-machine]` | as for status | as for status | as for status | `gateway.admin`, `gateway.admin_personal`, `gateway.*`, `cli.usage_errors` | API |
| `inference route --machine VM [--agent claude\|codex]` | `{ok, route: team_key\|owner_key\|owner_gateway\|team_gateway\|shared_coderouter, agent, machine}` | `cli.invalid_args` (2), `machine.edge_unreachable`, `machine.exec_failed`, `api.bad_answer`, `inference.keys_unreachable` | `reads_the_machine_probe`, `parses_status_mode_and_route` | `gateway.route_order`, `cli.usage_errors` | API |
| `inference gateway --personal ...` (serve) | log lines (no JSON) | exit 2 on bad usage | `cli/inference_gateway.rs`: `personal_selects_the_owner_gateway` | `gateway.start` harness (team gateway only) | API (WebSocket) |
| `link chat list --host ID` | `{team, machine, chats: [{surface, session, harness, cloud_id}]}` | `chat.bad_usage` (64), `chat.closed`, `remote_denied`; dial exits 2 to 6 | `link/chat_cli.rs`: `each_verb_parses_to_its_frames`, `help_names_every_verb`, `bad_usage_is_refused_before_any_dial` | `link.chat_owner`, `share.*` | Link |
| `link chat read --host ID --surface N [--after-seq N] [--limit N]` | `{session, events, hasMore, lastSeq, presence?}` | as for list, plus `agent_session.unknown_tab`, `agent_session.not_shared` | as for list | `link.chat_owner` | Link |
| `link chat send --host ID --surface N --text T [--steer] [--prompt-id P]` | `{prompt_id, turn_id, queued, state: steered\|queued\|started, awaiting_owner}` | as for read, plus `agent_session.not_trusted` | as for list | `share.guest_held`, `share.member_steer`, `cli.usage_errors` | Link |
| `link chat approve --host ID --surface N --prompt-id P --turn-id T --revision R` | the daemon's answer | `agent_session.owner_only`, `queue.stale`, `queue.not_found` | as for list; `acpmux/src/hub/queue_approve_tests.rs` | `share.guest_held`, `share.member_steer` | Link |
| `link chat decline --host ID --surface N --prompt-id P` | the daemon's answer | `agent_session.owner_only`, `queue.not_found` | as for approve | `link.chat_owner`, `share.guest_held` | Link |
| `cloud start-chat --from-folder PATH` (`--login` removed) | `{machine_id, session_id, host, ..., new_machine}` | `usage.invalid`, the steps' codes | `cli/cloud_start_chat/tests.rs`, `cli/cloud_start_chat/folder_tests.rs` | none | App |
| `cloud start-session --from-folder PATH` (`--login` removed) | the app's answer | the app's | `spec/fixtures/cli-action-requests.json` contract | none | App |
| `link seed fetch --socket P NEW REMOTE [--adopt] [--find-root]` | one JSON line | the seed's codes | `link/seed_cli.rs`: `parses_a_transfer_fetch_and_its_adopt_flag_only_there`; `tests/transfer_fetch_journey.rs`: 4 tests | none | Internal (Transfer to This Mac) |
| `link seed push --seed-only` | `seed_refused` with `fallback_code`, `copy_files`, `copy_bytes` | `seed_refused` | `tests/link_seed.rs`: `seed_only_refuses_instead_of_copying_and_says_what_a_copy_would_send` | none | Internal |
| `cloud team-sessions [--scope mine\|team\|following] [--by U] [--archived true] [--limit N] [--cursor C]` | `{team, sessions: [...], next_cursor}` | `cloud.signed_out`, `cloud.unreachable`, the API's | help only: `cli/cloud_help/tests.rs` `help_lists_exactly_the_offered_cloud_verbs` and the per-verb help tests | `app.team_read` | App |
| `cloud team-session --session S` | `{session}` | `cloud_session.invalid`, `cloud_session.not_cloud` | help only | `app.team_read`, `app.session_changes` | App |
| `cloud copy-session-link --session S` | `{link, key, kind, copied}` | as for team-session | help only | `app.team_read`, `app.session_changes` | App |
| `cloud follow` / `cloud unfollow --session S` | `{session}` | as for team-session | help only | `app.session_changes` | App |
| `cloud reassign --session S --to USER` | `{session}` | `validation.invalid`, as for team-session | help only | `app.session_changes` | App |
| `cloud archive-session --session S [--archived false]` | `{session}` | as for team-session | help only | `app.session_changes` | App |
| `cloud show-team-section` | the app's answer | none | help only | `app.team_read` | App |
| `cloud team-members` | `{members: [{user, name, role, you}]}` | `cloud.unreachable` | help only | `app.team_read` | App |
| `cloud group-members --group G` | `group.members.list`'s value | `validation.invalid`, the API's | help only | `app.team_read` | App |
| `cloud group-member-set --group G --user U --role owner\|edit\|view` | `group.members.set`'s value | `validation.invalid`, the API's | help only | `app.team_read` | App |
| `cloud group-member-remove --group G --user U` | `group.members.remove`'s value | `validation.invalid`, the API's | help only | `app.team_read` | App |
| `cloud transfer-local [--path DIR] --target tab:TAB` | the app's answer (progress in toasts) | the app's refusal | `cli-action-requests.json` contract (`cloud transfer-local --path`) | `app.transfer_local` | App |

Removed: `cmux cloud codex-holder` (`cli/cloud_codex_holder.rs`), the hidden `acp codex-auth-broker`, and `--login` on
`start-chat` and `start-session`.
