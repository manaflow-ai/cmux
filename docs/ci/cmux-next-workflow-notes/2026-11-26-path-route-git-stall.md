# path_route: end a stalled github.com fetch after 15 s

At path_route's `env:` in `.github/workflows/cmux-next.yml` (`GIT_HTTP_LOW_SPEED_*`).

Leo, 2026-11-25: "github actions is just there at the start and end or whatever maybe i guess, but we own the
in-between. all of it". path_route is the one job every pull request run waits on, and its work is about 25 s.
Run 45699717346 (cmux#53449, 2026-11-25) spent 4 min 34 s in it: the checkout's fetch from github.com stalled
twice with no bytes and git gave up only after the pool's 60 s low-speed limit each time (2 min 31 s; the third
try took 0.7 s), and the base-merge carry's fetch stalled 64 s more before it failed. The job's fetches are
depth 2 with `blob:none`, so a transfer with no bytes for 15 s is a stall, not a slow pack: git now ends it after
`vars.CI_ROUTE_GIT_STALL_SECONDS` (default 15) and actions/checkout's own retry, or the carry's `|| true`, takes
over. `vars.CI_ROUTE_GIT_STALL_SECONDS=0` puts back the 60 s. Only this job: a large fetch elsewhere can send
nothing while GitHub builds its pack. The root cause, the pool's git mirror reporting `mirror-not-ready` so every
fetch goes to github.com, is the pool's to fix.
