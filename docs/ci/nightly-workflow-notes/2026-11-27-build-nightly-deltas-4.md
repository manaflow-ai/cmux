# 2026-11-27-build-nightly-deltas-4

Above `- name: Yield the signer Mac to the nightly-next build loop` (job `build-nightly-deltas`) in `.github/workflows/nightly.yml`.

Before the keyed job asks for the signer Mac; scripts/ci/nightly_deltas_yield.py. Two signers (ultra1, cmux15)
do not wait for the loop (a build may still wait; see the script); one-mini mode or NIGHTLY_NEXT_SIGNERS=1 waits.
