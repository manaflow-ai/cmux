# publish-nightly: runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI_PUBL…`.

The release App key remains scoped to this protected environment. Publication uploads and writes feeds
at about one core (publish-nightly 64 s on 32 vCPU at 1.39 cores, .github/runners.json): with no owned
pool it takes the signing picker's Linux label, as keep-published-dsyms does, else the Linux 4 vCPU pool.
