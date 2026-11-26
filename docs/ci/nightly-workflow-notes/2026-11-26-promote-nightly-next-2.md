# 2026-11-26-promote-nightly-next-2

Above `await-release-surface-ack:` (job `promote-nightly-next`) in `.github/workflows/nightly.yml`.

Legacy approval waiter retained for contract compatibility; validated moves now happen in
promote-nightly-next without an environment approval. It reads no secret and writes nothing,
so cancelling it never leaves nightly-next half-moved; the newest request wins its group.
