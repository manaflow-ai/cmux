# publish-nightly: &x87

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `- &x87`.

cx-f76kf: decide reads NIGHTLY_NEXT_WRITER only when the run starts, and
the HQ Linux pipeline publishes nightly-next while it is linux, so the
gate reads it again live. vars.* is fixed at run start and GITHUB_TOKEN
cannot read variables: the release App reads it (Variables: read).
A failed mint leaves the token empty, and the gate refuses.
