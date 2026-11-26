# build-nightly-app: trace_dir="$RUNNER_TEMP/checkout-git-trace2"

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `trace_dir="$RUNNER_TEMP/checkout-git-trace2"`.

Run 45744507889 (11-26) failed here on a cold slot that had borrowed the mirror: its curl and git
fetch to github.com got 429 four times, then 403. The mirror (glaeda-git-mirror: main,
feat-cmux-next and nightly-next every 60 s) is the one GitHub reader on this host; read it first.
Every github.com git transfer this step makes is counted from git's own trace2 events (one file
per git process): the goal is 0 per nightly, the commit read from this host's mirror.
