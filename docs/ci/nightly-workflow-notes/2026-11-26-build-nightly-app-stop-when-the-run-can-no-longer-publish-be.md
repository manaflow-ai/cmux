# nightly.yml: job `build-nightly-app`, step "Stop when the run can no longer publish (before the upload)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The run cannot publish once a job publish-nightly needs, running beside
this one, has failed (run 40460194731 compiled and uploaded for 65 min
after its Ghostty helper failed): stop and give the Mac back. One read
of this attempt's jobs; a read error carries on. NIGHTLY_PUBLISH_PEERS
is derived from the needs graph by tests/test_nightly_stop_if_publish_doomed.py.
