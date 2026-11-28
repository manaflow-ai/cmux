# nightly-next-hedge: the same tip compiled on the other signer Mac

Leo: "YOU CANNOT HAVE A SINGLE LANE THAT IS UNRELIABLE FOR NIGHTLIES. YOU CANNOT. YOU MUST HAVE MORE."

Where: `.github/workflows/nightly.yml`, jobs `nightly-next-hedge` and `nightly-next-hedge-verdict`.

- `pick-nightly-next-signer` (`scripts/ci/nightly_next_signer_pick.py`) also writes `hedge_pin`: the signer
  Mac it did not take, only when that Mac is wholly free at pick time (no running tail job or build, no
  nightly-next-one waiting for it, a runner online). Otherwise `hedge_pin` is empty and the hedge skips.
- `nightly-next-hedge` checks out the same `build_sha` and runs nightly-next-one's compile steps (the same
  anchors) through "Build nightly app (Release)". No signing, notarizing, publishing or deltas; no App token
  mint and no store signing key (the web bundles build unsigned store packages). It holds the whole Mac like
  every owned-Mac job, so a tail job (pkg, dSYMs, deltas) that took the Mac between the pick and the start
  keeps it: the hedge queues behind it, it never takes the Mac.
- Nothing needs either job and both are `continue-on-error`, so the hedge can never turn the nightly red or
  hold up publishing. `vars.NIGHTLY_NEXT_HEDGE = off` turns it off.
- `nightly-next-hedge-verdict` (`scripts/ci/nightly_next_hedge_verdict.py`) writes one row per signer (role,
  host, sha, compile result, minutes) to the job summary and the `nightly-next-hedge-rows` artifact, and
  warns "flake signal" when one signer compiled the tree and the other did not.

Next (not built here): the full hedge through the publish lease, both signers build and sign, the R2
publish lease picks the one that publishes.
