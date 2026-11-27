# nightly.yml: job `promote-nightly-next-acked`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Moves nightly-next after the approval. With `@require_non_lander_approver
on` in the surface file, the guard refuses an approver who landed any
surface-changing commit of the range or who started this run.
