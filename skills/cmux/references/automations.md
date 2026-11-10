# Automations: when something happens, start an agent

`cmux automation` runs a prompt (an agent session) or a command when something happens, on a
schedule, when a condition script says so, or when a watched command prints a line. Every verb
has `--json`; the MCP tools `automation_*` are the same verbs (`automation_create` takes `when`).

## When something happens: `--when EVENT`

| Want | Command |
| --- | --- |
| Review every pull request you or an agent open | `cmux automation create review --when pr-opened --prompt "Review this pull request and comment"` |
| Pick up after an agent stops | `cmux automation create next-step --when agent-idle --prompt "Read what the agent did and say what is next"` |
| Answer for a stuck agent | `cmux automation create unblock --when agent-needs-input --prompt "..."` |

`cmux automation events` lists the events (MCP `automation_events`), each with where it comes
from and how late it can be: `agent-idle` and `agent-needs-input` arrive within seconds;
`pr-opened` is read from GitHub through `gh` every 5 minutes (nothing pushes GitHub changes to
cmux yet), so it can be up to 5 minutes late. `cmux automation events NAME` prints that event's
lines live, one JSON object each; the same line reaches `--if` on stdin and the prompt under
"Event", so `--when pr-opened --if 'jq -e ".repo == \"me/app\""'` narrows it to one repo.
Do not hand-write a `--watch` for these. `cmux automation edit NAME --when agent-idle` changes
the event; the Automations page shows it in words ("When a pull request is opened").

## The ladder

| Want | Command |
| --- | --- |
| An event | `cmux automation create review --when pr-opened --prompt "Review this pull request"` |
| A timer | `cmux automation create digest --every 1h --prompt "Summarize new issues"` |
| A timer that runs only when a check passes | `... --every 10m --if ./errors-up.sh --prompt "..."` |
| A run per log burst | `... --watch 'tail -n 0 -F app.log \| grep --line-buffered FATAL' --prompt "Fix this crash"` |
| Both | `... --watch '...' --if ./is-new-crash.py --prompt "..."` |

Triggers: `--when EVENT [--debounce 5s]`, `--hourly`, `--daily 09:00`, `--weekdays 09:00`, `--weekly "fri 17:00"`, `--every 30m`,
`--at`, `--in 2h`, `--cron "0 9 * * 1-5"`, `--manual`, `--watch CMD [--debounce 5s]`.

## The script contract

- `--if CMD` runs with `/bin/sh -c` in `--folder`, the event on stdin (empty for a timer).
  Exit 0 runs the body and its stdout joins the prompt; exit 1 records `skipped:
  condition_false`; any other exit, or more than 60 s, fails the run. It must only read: `test`
  runs it too.
- `--watch CMD` is a long-running command; every stdout line is an event. Lines closer than the
  debounce (1 to 30 s) are one event, and a stream that never pauses is one event every 30 s.
  When the command's output closes, it is stopped and starts again after a backoff. Use
  `tail -n 0 -F` (not `-f`) and `grep --line-buffered`.
- The event reaches a prompt as quoted data under "Event", and a command body as
  `$CMUX_AUTOMATION_EVENT_FILE`. Also set: `CMUX_AUTOMATION_ID`, `CMUX_AUTOMATION_RUN_ID`,
  `CMUX_AUTOMATION_TRIGGER`.

## Guardrails

One live run per automation, always (a manual `run` beside a live run is recorded
`skipped: previous_run_running`). `--cooldown 10m` and `--max-runs N` (in 24 h) bound how
often it runs; a watch gets `--cooldown 10m --max-runs 24` and each event its own defaults
(`agent-idle`: 1m and 48; `pr-opened`: no cooldown, 24) unless you set them (`0` turns one
off). An automation run's own session (`auto-...`) never fires an agent event. Watch events that arrive while a run is live or cooling down are counted, not run (`show`
prints the count, the next run's prompt says it), so a run's own fix cannot loop.

## Before you say it works

1. `cmux automation test NAME --event "sample line"`: the condition's result and output, the
   guardrail verdict, and the exact prompt. Exit 0: it would run now; 1: it would not, and why.
   For a `--when` automation, no `--event` uses that event's sample line.
2. `cmux automation run NAME --event "sample line" --wait` for one real run, then
   `cmux automation history NAME` and `cmux automation logs NAME`.
3. Schedules and watches need the runner: `cmux automation runner status`, else
   `cmux automation runner install` (or `cmux automation runner` in a terminal).

`--target cloud` runs prompt automations on cmux Cloud with the Mac asleep; `--if`, `--watch`
and `--when` run on this machine only.
