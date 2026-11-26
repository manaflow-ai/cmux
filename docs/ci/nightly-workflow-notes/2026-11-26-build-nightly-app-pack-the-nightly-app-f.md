# build-nightly-app: Pack the nightly app for reuse

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `- name: Pack the nightly app for reuse`.

A failed or cancelled job leaves no background helper build running.
The record a later build looks up; record=true only on a fresh VM that started clean.
