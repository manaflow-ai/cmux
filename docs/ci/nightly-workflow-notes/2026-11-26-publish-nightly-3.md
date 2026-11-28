# 2026-11-26-publish-nightly-3

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.04' && 'cmux-gcp-nightly-jit-x64' || vars.CI_NIGHTLY_MINI != '' && 'glaeda-trusted-next-signing' || needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && needs.pick-nightly-sign-runner.outputs.sign_owned_pool || 'glaeda-trusted-next-signing' }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

The release App key remains scoped to this protected environment. Publication uploads and writes feeds
at about one core (publish-nightly 64 s on 32 vCPU at 1.39 cores, .github/runners.json): with no owned
pool it takes the signing picker's Linux label, as keep-published-dsyms does, else the Linux 4 vCPU pool.

## nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

rc/** branches share one release. Serialize its mutable aliases and feeds
by channel, even when workflow-level groups have different branch names.
nightly-next takes a group of its own run and the R2 lease below instead:
a shared group cancelled run 41436891188's pending publish for a newer one.
