# nightly.yml `publish-nightly-next-github`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}`

An upload holds the release App key but signs nothing: a fresh hosted VM per job, so no other job shares it and
the signer stays free for the next sign (one-mini mode too: on the mini it would need the whole-Mac claim).

## 2

Above: `- *github-token-for-git`

Only the source archive reads the build's tree; every other step runs .publish-tooling. The full
checkout took 2 min of the whole Mac on run 42018687632, whose archive step was off.

## 3

Above: `- name: Take the release names lease`

The mutable state, only for the live feed's newest build. A failed write here leaves the immutable
assets above published and the job green (continue-on-error); the next build's run writes them.
One names writer at a time across runs, push or dispatch (the names job's group did this): its own
R2 lease (publish-lease.sh), which never cancels a waiter. Each write runs still-newest inside it.
