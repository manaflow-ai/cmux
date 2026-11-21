# Rolling chat summaries with a next action

Landed on feat-cmux-next as 2b0666ec189..4f7ab0f00b4 (David Beyer, 2026-11-20: "rolling
summaries of every chat with a next action for each").

- `hub/rolling_summary.rs` (new): after a turn ends, the chat gets `rollingSummary`
  `{text, next?, source: "wrap_up" | "model", turn, at}` on `SessionMeta`, `SessionSummary` and
  `SessionDetail`. The change goes in the session log as a `summarized` record and goes out as
  `_acpmux/session_changed`.
- Cost: when a turn ends on an `acpmux wrap_up` call, the summary is its recap and ask, with no
  model call. Otherwise only a turn that a person started (`prompt_sender::person_turn`) makes
  one call to the summary command. The call sends the last summary, the prompt (at most 1,500
  characters) and the end of the reply, never the transcript, with `max_tokens` 80 and a 30 s
  timeout. A turn that another agent started makes no call.
- Config `summaries`: `generate` (default on; when it is off, no model call runs, but a wrap-up
  still sets the summary), `command` (an argv; the env `ACPMUX_SUMMARY_COMMAND` wins; unset:
  one `_acpmux/complete` on the chat's own harness) and `model` (unset: `titles.model`, else
  the harness's small model, `haiku` on Claude).
- `hub/titles.rs`: `run_command(cmd, request, timeout)` is now shared by titles and summaries.
  `run` stays `pub(super)` because `task_names.rs` calls it.
- `hub/turns.rs`: turn start calls `summary_turn_started(session, person)` next to
  `recap_turn_started`, and turn end calls `summary_turn_ended`.
- Protocol IR: `RollingSummary` type, and the `rollingSummary` property on `SessionSummary`
  and `SessionDetail`. The web types are regenerated.
- Tests: `tests/rolling_summaries.rs` (4 tests, red first in 2d2cca85c98) with
  `tests/fake_summarizer.py`. No test reaches a model. Fleet steps: Rust summaries
  83fe6a9db8bf72d6bede0548 and protocol IR 30816a12c486539d97c23b73.
