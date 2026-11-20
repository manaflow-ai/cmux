# Background start uncertainty

The background-shell rewrite in #47746 retried the command after every start RPC error. A lost reply or a post-launch error could therefore execute a command twice.

`bg_hook` now distinguishes failure before submission from an uncertain submitted request. Only the former emits the explicit safe-fallback status through the CLI's typed-error path. Other failures preserve their status and tell the caller to inspect existing tasks before retrying. Successful starts and subagent routing stay unchanged; this adds no background loop or persistent state.

Detectors: `the_rewritten_shell_never_repeats_a_start_whose_reply_was_lost` counts one execution under both sh and bash; `the_rewritten_shell_runs_the_command_only_when_the_daemon_did_not_start_it` covers fallback and error statuses; `background_start_without_a_session_explicitly_allows_shell_fallback` exercises the hidden CLI's pre-submission status. Fleet execution is required before reporting them passed.
