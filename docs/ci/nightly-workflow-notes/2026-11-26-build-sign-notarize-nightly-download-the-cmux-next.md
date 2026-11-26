# build-sign-notarize-nightly: Download the cmux-next source archive for recovery

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `- name: Download the cmux-next source archive for recovery`.

A later run publishes this build from the recovery artifact alone, so
it also carries the SSH daemon assets and, when published, the source
archive (their own artifacts expire after 3 days).
