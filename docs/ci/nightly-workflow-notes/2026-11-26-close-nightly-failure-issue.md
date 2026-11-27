# nightly.yml: job `close-nightly-failure-issue`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

always(): a skipped notes job must not skip this job silently; the
conditions below decide. nightly-next closes only with its notes published,
unless it published a recovered build, which has none (cx-urd.69). A
recovered build can follow this run's own failed build, which reports.
It closes in the run that ran the notes and deltas (run_tail): on nightly-next, the dispatched one. There
it cannot see the run that published, so push_clean says none of that run's jobs failed.
