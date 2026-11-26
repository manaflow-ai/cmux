# 2026-11-26-generate-nightly-deltas-2

Above `- &forget-kept-sparse-mode` (job `generate-nightly-deltas`) in `.github/workflows/nightly.yml`.

The kept clone remembers the last checkout's sparse mode. After the signer's pattern checkout
(core.sparseCheckout=true, no cone setting) git reads the cone request below as the one pattern
`scripts`, so the root .xcode-version stays out and Select Xcode fails here (runs 42819750253,
42829570644: no deltas). The warm checkout's manual sparse test runs this step.
