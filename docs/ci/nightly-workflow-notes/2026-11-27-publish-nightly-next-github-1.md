# 2026-11-27-publish-nightly-next-github-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}` (job `publish-nightly-next-github`) in `.github/workflows/nightly.yml`.

An upload holds the release App key but signs nothing: a fresh hosted VM per job, so no other job shares it and
the signer stays free for the next sign (one-mini mode too: on the mini it would need the whole-Mac claim).
