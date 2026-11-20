# Chief build handoff experiment

This is the first slice of the private
[`plans/multiplayer-chief/DESIGN.md`](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/plans/multiplayer-chief/DESIGN.md),
section 8. It wraps the installed `cmux-ci` client. The fleet remains the owner of
build scheduling, credentials, logs, signing and artifacts.

## Try it

The existing **Settings > Advanced > Labs > Show Preview Features** toggle
(`labs.previewFeatures`) is false by default. Enable it on the daemon serving
the caller. The experiment reads the effective setting through `settings.get`;
missing, malformed, false or unreachable settings refuse before any submission.
The command does not enable its own gate.

From the shared host, after committing and pushing the desired commit:

```sh
cmux chief build --ref FULL_40_CHARACTER_SHA --tag chief-example \
  --workspace DURABLE_WORKSPACE_OR_PR_URL --receipt ./chief-build.json --timeout 600
```

Run the same command and receipt again after a wait timeout. The saved job ID
is reused; it does not submit another build. `--timeout` is the wait budget,
not a build deadline. A timed-out wait leaves the fleet job running.

The design's `chief-build` spelling is available as the repository's thin
`scripts/chief-build` launcher, which forwards to the same Rust command.

## Receipts and recovery

The caller chooses a durable receipt path in a directory it owns. Keep its files:

- `chief-build.json.chief-request.json`: commit, tag and workspace reservation,
  written with create-new semantics before invoking the fleet client.
- `chief-build.json`: the fleet's accepted submission, including job ID.
- `chief-build.json.pending`: the fleet client's ambiguous-submission marker.
- `chief-build.json.terminal.json`: the most recent fleet wait receipt.

Concurrent invocations cannot both reserve the same receipt. Reusing a receipt
with different inputs refuses. A reservation without an accepted receipt stops;
inspect `cmux-ci status` and reconcile the original request before doing anything
else. Do not delete the reservation to retry an ambiguous submission. This can
also happen if the process stops immediately before submission: uncertainty is
preserved rather than interpreted as permission to submit again.

The wrapper validates the accepted receipt's exact commit, build kind, workspace
and job ID before waiting. It passes argument arrays directly to `cmux-ci` with
no shell interpolation. Submission has a 15-minute helper bound; each wait has
its requested timeout plus a 90-second local helper margin. Terminating a local
helper does not cancel the fleet job.

A build result is not test evidence. Run relevant tests separately.

## Scope and surfaces

This is a host CLI experiment. People and agents on a host with the existing
fleet client and credentials use the same Rust path. The existing Labs setting
retains its generated Settings, palette, CLI and MCP controls. No default changes.

There is no new native action, context menu, shortcut or direct phone build
submission in this slice: fleet credentials and durable local receipt ownership
belong to the invoking host, and exposing them through a remotely callable
action needs an explicit authenticated build owner first. An agent instructed
from a phone or shared chat can invoke the same host CLI. This slice adds no
new remote rights, listener, Chief service, model route or shared-chat store.

The design's shared host capacity and service quotas are deployment bounds,
not latency targets. This slice provisions no machine and makes no before/after
performance claim.

## Verification

The `chief_build` Rust tests exercise default-off parsing, exact identities,
concurrent reservations, lost submission replies, malformed receipts and a
timed-out wait followed by a successful wait on the same ID. Run them on the
fleet with the existing `scripts/ci/cmux-tui-rust-check.sh` test mode, filter
`chief_build`, scope `cmux-tui`.
