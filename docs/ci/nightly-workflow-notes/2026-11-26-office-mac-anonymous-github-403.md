# Office Macs: anonymous github.com requests get 403

In the "Checkout build ref (warm nightly-next builder)" step of `.github/workflows/nightly.yml`, and in
`restore_bun_darwin` of `scripts/ci/toolchain-r2.sh`.

Every office Mac (the glaeda minis, the ultras) reaches github.com from one address, and GitHub budgets
anonymous git and download requests per address. The warm builder fetched `BUILD_SHA` with no credentials,
and setup-bun downloads its release with none, so a busy hour spent that shared budget and GitHub answered
403: run 45763487534 (2026-11-26 05:43Z) job 139719742058 on cmux7s-mac-mini-glaeda-nightly-only-6 failed
its lazy fetch with 403 at 05:46:49.19 while actions/checkout's authenticated fetch on the same Mac passed
at 05:46:49.60; run 45756842046 (04:44Z) failed on ultra1-glaeda-1 (job 139720553270) and cmux15-glaeda
(job 139699238706) with setup-bun's "Unexpected HTTP response: 403"; more from 01:13Z to 01:50Z.

So the fetch carries the job token the way actions/checkout does: an `http.extraheader` passed through
`GIT_CONFIG_COUNT` in the step's environment, masked, never written to `.git/config`. And setup-bun's
downloads mostly stop: `~/.bun/bin/bun` is shared by a Mac's runner instances and workflows pinning other
versions swap it, so before setup-bun the restore step keeps the bun it finds under
`~/.bun/cmux-versions/VERSION` and puts the pinned one back from there, where setup-bun takes it with no
download. A version the store lacks is downloaded once per Mac and checked against its darwin pin in
`scripts/ci/toolchain-archives.sha256`; any miss exits 0 and setup-bun runs as before. The fleet's own
ci-steps go through the controller's authenticated git proxy instead (cmuxterm-hq#27543, handbook page
`anonymous-fetches-share-one-address`).
