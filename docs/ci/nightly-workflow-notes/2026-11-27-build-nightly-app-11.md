# 2026-11-27-build-nightly-app-11

Above `- name: Pack the nightly app for reuse` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

A failed or cancelled job leaves no background helper build running.
The record a later build looks up; record=true only on a fresh VM that started clean.
