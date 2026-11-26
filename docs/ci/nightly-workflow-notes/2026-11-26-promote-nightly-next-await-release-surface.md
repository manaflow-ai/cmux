# promote-nightly-next: await-release-surface-ack:

Where: the `promote-nightly-next` job in `.github/workflows/nightly.yml`, above `await-release-surface-ack:`.

Legacy approval waiter retained for contract compatibility; validated moves now happen in
promote-nightly-next without an environment approval. It reads no secret and writes nothing,
so cancelling it never leaves nightly-next half-moved; the newest request wins its group.
