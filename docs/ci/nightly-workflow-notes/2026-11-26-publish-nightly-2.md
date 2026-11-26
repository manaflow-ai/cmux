# nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The release App key remains scoped to this protected environment. Publication uploads and writes feeds
at about one core (publish-nightly 64 s on 32 vCPU at 1.39 cores, .github/runners.json): with no owned
pool it takes the signing picker's Linux label, as keep-published-dsyms does, else the Linux 4 vCPU pool.
