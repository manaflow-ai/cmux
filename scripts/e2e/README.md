# scripts/e2e - iOS E2E drivers

Driver contract for [.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml).
The workflow owns runner selection, tailnet join, GCP backend provisioning,
both app builds, relay-only configuration, simulator lifecycle, evidence
upload, and cleanup. `ios-e2e-run.sh` owns the six terminal steps after the
apps are signed in, paired, and connected.

## ios-e2e-run.sh

Drives an already signed-in, paired, connected simulator through the six-step
terminal script against a real streamed terminal. The workflow owns sign-in,
pairing, and connection setup; the driver receives the run identity and
simulator explicitly through flags.

| Flag | Meaning |
| --- | --- |
| `--tag <tag>` | Shared Mac/iOS dev tag; pairing is tag-scoped. |
| `--sim-udid <udid>` | Exact booted simulator owned by this run. The driver passes this UDID to every simctl call. |
| `--evidence-dir <dir>` | Directory for screenshots, streamed-grid text dumps, and device logs. The workflow uploads it verbatim (`if: always()`). |
| `--bundle-id <id>` | Optional installed bundle override. Without it, the driver discovers the isolated `dev.cmux.*` bundle on the simulator. |
| `--step-timeout <seconds>` | Optional bounded wait per terminal step; default 45 seconds. |

| Env | Meaning |
| --- | --- |
| `CMUX_DEV_BACKEND_URL` | Web API origin used for sign-in and pairing. The workflow obtains it from `scripts/e2e/gcp-backend.sh url --tag`. |
| `CMUX_IROH_BROKER_BASE_URL` | Same backend origin baked into both app builds for broker discovery. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | Same account used by the Mac and simulator. The workflow stores it as `CMUX_UITEST_*` in a mode `0600` file for the `agent` profile. |

The workflow sets `CMUX_IROH_V2_FORCE_RELAY=1` for the Mac build and writes the
relay-only defaults for both installed app bundles before
`mobile-dev-launch.sh` starts the simulator. The driver assumes that policy is
already configured; it does not switch transport modes during a step.

On failure exit nonzero and print `E2E FAIL step=<id>` as the last stderr line,
where `<id>` is a step id below or `sign-in`, `pair`, `connect` for setup.

### The six-step terminal script

Each step covers a shipped regression; do not weaken a step without replacing
its coverage.

1. `marker-1` - type `echo E2E-<run>-A` into the streamed terminal and assert
   the echoed marker renders in the grid within a bounded wait. Proves the
   full live keystroke path: iOS key -> Iroh -> Mac PTY -> stream -> grid.
   Regression: input echo stall, caught only by marker-echo liveness
   ([#12927](https://github.com/manaflow-ai/cmux/pull/12927)).
2. `burst-scrollback` - run `seq 1 5000`, wait for the tail, scroll back and
   assert an early line and the final line are both intact. Proves ordered
   byte-tee append and scrollback integrity under burst output.
   Regression: O(chunk^2) byte-tee append and viewport livelock
   ([#13432](https://github.com/manaflow-ai/cmux/pull/13432)).
3. `alt-screen` - open `less` on a real file, assert the alt-screen UI
   rendered, quit with `q`, and assert the primary screen is restored.
   Regression: alt-screen transition freeze
   ([#12844](https://github.com/manaflow-ai/cmux/pull/12844)).
4. `interrupt` - start `sleep 30`, send Ctrl-C, and assert the prompt returns.
   Proves control-byte delivery independently of the output path.
5. `replay` - background the iOS app, relaunch it, and assert the reconnected
   grid replays the missed content rather than staying blank.
   Regression: a black-holed QUIC path kept installed and left the terminal
   blank on replay ([#14030](https://github.com/manaflow-ai/cmux/pull/14030)).
6. `marker-2` - type `echo E2E-<run>-B` and assert it echoes. Proves the
   session is still live for input after reconnect and recovery.
   Regression: a pre-bootstrap recovery cooldown stalled a fresh session
   ([#14124](https://github.com/manaflow-ai/cmux/pull/14124)).

The workflow stops the tagged Mac app, deletes the isolated simulator, removes
the tagged backend stack, and deletes the temporary credentials file after the
driver exits, including on failure.
