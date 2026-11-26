# build-nightly-deltas: Yield the signer Mac to the nightly-next build loop

Where: the `build-nightly-deltas` job in `.github/workflows/nightly.yml`, above `- name: Yield the signer Mac to the nightly-next build loop`.

Before the keyed job asks for the signer Mac; scripts/ci/nightly_deltas_yield.py. Two signers (ultra1, cmux15)
do not wait for the loop (a build may still wait; see the script); one-mini mode or NIGHTLY_NEXT_SIGNERS=1 waits.
