# publish-nightly-next-github: runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux

Where: the `publish-nightly-next-github` job in `.github/workflows/nightly.yml`, above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64…`.

An upload holds the release App key but signs nothing: a fresh hosted VM per job, so no other job shares it and
the signer stays free for the next sign (one-mini mode too: on the mini it would need the whole-Mac claim).
