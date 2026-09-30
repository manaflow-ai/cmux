# scripts/e2e — iOS E2E drivers

Driver contract for [.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml).
The workflow owns runner selection, tailnet join, product download, the
backend stack, evidence upload, and the teardown signal; these scripts own
everything on the runner between "app product on disk" and "verdict". The
interface is environment variables only, no flags — keep it stable, the
workflow and the scripts land from different PRs.

## mac-host.sh

Launches the tagged Mac app, signs it into the CI Stack account, advertises it
through the dev backend so the iOS client can discover and pair with it, then
blocks until the iOS job signals completion.

| Env | Meaning |
| --- | --- |
| `CMUX_E2E_TAG` | Shared dev tag for this run (`ci<PR#>` or `ci-main`). Names the app bundle (`com.cmuxterm.app.debug.<tag>`), the debug socket (`/tmp/cmux-debug-<tag>.sock`), and the backend stack. |
| `CMUX_DEV_BACKEND_URL` | Web API origin of the ensured backend stack (private Tailscale Serve URL on the durable VM). |
| `CMUX_E2E_DONE_FILE` | Absolute path of the teardown file. Poll for it locally (sleep loop); the iOS job touches it over Tailscale SSH. Never substitute GitHub API status polling — a ~25-minute per-PR poll loop draws down the repo-wide API rate limit, and the file needs no token. |
| `CMUX_E2E_WAIT_TIMEOUT_SECONDS` | Optional bound on the done-file wait; default 1500 (~25m). Expiry exits 0 as an infrastructure timeout. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | Dedicated CI Stack account (the pair ios-streamed-validate.yml uses; the app's dev-secrets resolution reads `CMUX_DOGFOOD_STACK_*` from the environment first). Never echo, never pass on argv, never write to disk. |

Exit 0 means the app launched, signed in, advertised, and the done-file
appeared in time. On failure exit nonzero and name the phase on the last
stderr line: `launch`, `sign-in`, `advertise`, or `wait-timeout`.

## ios-e2e-run.sh

Signs the simulator app in, pairs it to the remote Mac through the backend,
connects over Iroh, and drives the 6-step terminal script against a real
streamed terminal.

| Env | Meaning |
| --- | --- |
| `CMUX_E2E_TAG` | Same shared tag as the Mac host (bundle `dev.cmux.ios.<tag>`); pairing is tag-scoped, so a tag mismatch can never pair. |
| `CMUX_DEV_BACKEND_URL` | Web API origin used for sign-in and pairing. |
| `CMUX_E2E_SIM_UDID` | The freshly created, booted simulator this run owns. Pass it to every simctl/idb call; never resolve by name. |
| `CMUX_E2E_EVIDENCE_DIR` | Directory for screenshots, streamed-grid text dumps, and device logs; the workflow uploads it verbatim (`if: always()`). Write a capture at every step boundary, pass or fail. |
| `CMUX_E2E_BACKGROUND_SECONDS` | Optional background interval for the replay step. Set to `120` or more to enforce the two-second resume-to-Mac-input budget and write `background.json`. |
| `CMUX_E2E_VIDEO` | Optional simulator video output path. The driver records the whole run and stops the recorder during cleanup. |

| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | Same account as the Mac host — pairing's same-account RPC gate requires both ends to resolve one account. Same secrecy rules. |

`iroh-codex-workload.sh` starts three real `codex --yolo -m gpt-5.5-mini` sessions in separate Mac workspaces and two supporting workspaces. It records workspace, surface, model, and observed output markers in `codex-workload.jsonl`; set `CMUX_CODEX_DURATION_SECONDS` to keep the sessions active while the iOS gate runs.

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
