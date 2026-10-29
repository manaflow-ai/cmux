# The shapes the nightly-next tick's scripts accept from GitHub's Actions API: one schema per object,
# covering every field any of them reads (nightly_next_stuck_run.sh, nightly_next_cancelled_tip.sh,
# nightly_next_rerun.sh, nightly_next_tip_owed.sh; nightly_repick.py reads the same jobs). Each
# definition passes a well-formed object through and is a jq error for anything else, so a read that
# meets an unexpected shape fails, and a failed read cancels, re-runs and dispatches nothing.
# jq renders a null or an object as text ("null", "{}") that no later pattern can tell from a real
# value, so a field is checked here, by its JSON type, before anything formats or compares it.
#
# Load with: jq -L DIR 'include "nightly_next_shapes"; ...' (gh --jq cannot include, so the scripts
# fetch the raw JSON with gh and run jq on it).

def str_or_null: type == "string" or type == "null";

# A workflow run (the runs list and a single run read).
def typed_run:
  if type == "object"
     and (.id | type) == "number"
     and (.event | type) == "string"
     and (.status | type) == "string"
     and (.conclusion | str_or_null)
     and (.run_attempt | type) == "number"
     and (.head_sha | type) == "string" and (.head_sha | test("^[0-9a-f]{40}$"))
     and (.display_title | str_or_null)
  then . else error("a run of an unexpected shape") end;

# A job of a run's jobs list. A queued job is judged by its label, so it must have one; a finished
# job may report none (GitHub gives a skipped job labels []).
def typed_job:
  if type == "object"
     and (.id | type) == "number"
     and (.name | type) == "string"
     and (.status | type) == "string"
     and (.conclusion | str_or_null)
     and (.runner_name | str_or_null)
     and (.labels | type) == "array" and all(.labels[]; type == "string")
     and (.status != "queued" or (.labels | length) > 0)
     and (.created_at | type) == "string" and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$"))
  then . else error("a job of an unexpected shape") end;

# A page of a list: its KEY must be an array.
def page_of(key): if type == "object" and (.[key] | type) == "array" then .[key][] else error("not a list") end;
