# 2026-11-26-publish-nightly-next-github-1

Above `- name: Take the release names lease` (job `publish-nightly-next-github`) in `.github/workflows/nightly.yml`.

The mutable state, only for the live feed's newest build. A failed write here leaves the immutable
assets above published and the job green (continue-on-error); the next build's run writes them.
One names writer at a time across runs, push or dispatch (the names job's group did this): its own
R2 lease (publish-lease.sh), which never cancels a waiter. Each write runs still-newest inside it.
