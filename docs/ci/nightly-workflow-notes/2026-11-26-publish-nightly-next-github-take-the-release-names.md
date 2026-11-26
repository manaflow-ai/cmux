# publish-nightly-next-github: Take the release names lease

Where: the `publish-nightly-next-github` job in `.github/workflows/nightly.yml`, above `- name: Take the release names lease`.

The mutable state, only for the live feed's newest build. A failed write here leaves the immutable
assets above published and the job green (continue-on-error); the next build's run writes them.
One names writer at a time across runs, push or dispatch (the names job's group did this): its own
R2 lease (publish-lease.sh), which never cancels a waiter. Each write runs still-newest inside it.
