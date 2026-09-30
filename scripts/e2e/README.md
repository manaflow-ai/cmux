# scripts/e2e — iOS E2E drivers

Driver contract for [.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml).
The workflow owns runner selection, tailnet join, product download, the
backend stack, evidence upload, and the teardown signal; these scripts own
everything on the runner between "app product on disk" and "verdict". The
scripts have separate interfaces. `mac-host.sh` is configured through
environment variables. `ios-e2e-run.sh` requires flags for the run identity and
uses environment variables for shared credentials and backend state.

## mac-host.sh

Launches the tagged Mac app, signs it into the CI Stack account, advertises it
through this run's backend so the iOS client can discover and pair with it,
then blocks until the iOS job signals completion.

| Env | Meaning |
| --- | --- |
| `CMUX_E2E_TAG` | Tag the prebuilt products are stamped with (`e2eci`). Names the app bundle (`com.cmuxterm.app.debug.<tag>`) and the debug socket (`/tmp/cmux-debug-<tag>.sock`). |
| `CMUX_IROH_V2_BASE_URL`, `CMUX_PRESENCE_BASE_URL`, `CMUX_API_BASE_URL`, ... | This run's backend origins, from `backend-env.sh env`. Required: the script execs the app binary so they win over the LSEnvironment baked into the build. |
| `CMUX_E2E_DONE_FILE` | Absolute path of the teardown file. Poll for it locally (sleep loop); the iOS job touches it over Tailscale SSH. Never substitute GitHub API status polling — a ~25-minute per-PR poll loop draws down the repo-wide API rate limit, and the file needs no token. |
| `CMUX_E2E_WAIT_TIMEOUT_SECONDS` | Optional bound on the done-file wait; default 1500 (~25m). Expiry exits 0 with phase `wait-timeout`; setup failures exit nonzero. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | Dedicated CI Stack account (the pair ios-streamed-validate.yml uses; the app's dev-secrets resolution reads `CMUX_DOGFOOD_STACK_*` from the environment first). Never echo, never pass on argv, never write to disk. |

Exit 0 means the app launched, signed in, and either received the done-file or
reached the bounded `wait-timeout`. On failure exit nonzero and name the phase
on the last stderr line: `launch`, `socket`, `sign-in`, or `wait-timeout`.

## backend-up.sh and backend-env.sh

`backend-up.sh up` starts this run's backend on the Linux runner: Postgres,
`web/`, and the iroh-v2 and presence Workers with their Durable Objects in
local workerd, published by Tailscale Serve on the runner's tailnet name.
`backend-up.sh hold` then serves until `CMUX_E2E_BACKEND_DONE_FILE` appears.
`backend-env.sh env` prints the app-side origins for that name, and
`backend-env.sh wait` blocks until all three answer. Contract and caching:
[docs/ci/ios-e2e.md](../../docs/ci/ios-e2e.md#per-run-backend).

## ios-e2e-run.sh

Drives an already signed-in, paired, connected simulator through the 6-step
terminal script against a real streamed terminal. The workflow owns sign-in,
pairing, and connection setup; the driver receives the resulting run identity
and simulator explicitly through flags.

| Flag | Meaning |
| --- | --- |
| `--tag <tag>` | Shared Mac/iOS dev tag; pairing is tag-scoped. |
| `--sim-udid <udid>` | Exact booted simulator owned by this run. The driver passes this UDID to every simctl call. |
| `--evidence-dir <dir>` | Directory for screenshots, streamed-grid text dumps, and device logs. The workflow uploads it verbatim (`if: always()`). |
| `--bundle-id <id>` | Optional installed bundle override. Without it, the driver discovers the isolated `dev.cmux.*` bundle on the simulator. |
| `--step-timeout <seconds>` | Optional bounded wait per terminal step; default 45 seconds. |

| Env | Meaning |
| --- | --- |
| `SIMCTL_CHILD_CMUX_IROH_V2_BASE_URL`, ... | This run's backend origins, from `backend-env.sh env --simctl`, inherited by the app simctl launches. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | Same account as the Mac host; pairing's same-account RPC gate requires both ends to resolve one account. Same secrecy rules. |

On failure exit nonzero and print `E2E FAIL step=<id>` as the last stderr
line, where `<id>` is a step id below or `sign-in`, `pair`, `connect` for the
setup phases.

### The 6-step terminal script

Each step covers a shipped regression; do not weaken a step without replacing
its coverage.

1. `marker-1` — type `echo E2E-<run>-A` into the streamed terminal and assert
   the echoed marker renders in the grid within a bounded wait. Proves the
   full live keystroke path: iOS key → Iroh → Mac PTY → stream → grid.
   Regression: input echo stall, caught only by marker-echo liveness
   ([#12927](https://github.com/manaflow-ai/cmux/pull/12927)).
2. `burst-scrollback` — run `seq 1 5000`, wait for the tail, scroll back and
   assert an early line and the final line are both intact. Proves ordered
   byte-tee append and scrollback integrity under burst output.
   Regression: O(chunk²) byte-tee append and viewport livelock
   ([#13432](https://github.com/manaflow-ai/cmux/pull/13432)).
3. `alt-screen` — open `less` on a real file, assert the alt-screen UI
   rendered, quit with `q`, assert the primary screen (step 2's tail) is
   restored. Proves the atomic alt-screen swap both directions.
   Regression: alt-screen transition freeze
   ([#12844](https://github.com/manaflow-ai/cmux/pull/12844)).
4. `interrupt` — start `sleep 300`, send Ctrl-C, assert the prompt returns.
   Proves control-byte delivery works independently of the output path; an
   interrupt that only lands on an idle stream is broken.
5. `replay` — background the iOS app (or drop the connection), generate
   output on the Mac side, foreground, and assert the reconnected grid
   replays the missed content rather than staying blank.
   Regression: black-holed QUIC path kept installed, terminal blank on replay
   ([#14030](https://github.com/manaflow-ai/cmux/pull/14030)).
6. `marker-2` — type `echo E2E-<run>-B` and assert it echoes. Proves the
   session is still live for INPUT after the churn of steps 2–5: reconnect
   and recovery must not have wedged the transport behind a cooldown.
   Regression: pre-bootstrap recovery armed a cooldown that filtered Iroh
   and stalled the fresh session
   ([#14124](https://github.com/manaflow-ai/cmux/pull/14124)).

The workflow — not this script — signals the Mac host's done-file over
Tailscale SSH after this script exits, pass or fail.
