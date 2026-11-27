# 2026-11-26-build-nightly-app-7

Above `- name: Stop when the run can no longer publish (before the compile)` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

The run cannot publish once a job publish-nightly needs, running beside
this one, has failed (run 40460194731 compiled and uploaded for 65 min
after its Ghostty helper failed): stop and give the Mac back. One read
of this attempt's jobs; a read error carries on. NIGHTLY_PUBLISH_PEERS
is derived from the needs graph by tests/test_nightly_stop_if_publish_doomed.py.
