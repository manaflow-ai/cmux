# cmux-next.yml: job `path_route`, "Pool mirror: Checkout"

Moved out of `.github/workflows/cmux-next.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

`cmux-next path routing` runs once per cmux-next run, about 7,500 times a day, at a mean of 31 s (timing feed,
6 h to 2026-11-27 15Z: 1,891 jobs, 979 runner-min). On a cmux-runner-pool VM (1,888 of the 1,891), about 10 s of
that was the checkout: actions/checkout's blob:none fetch (4-6 s, jobs 140582465151 and 140582215506) and the
parallel blob prefetch that widens it (4-5 s).

On a pool VM the job now checks out like the light jobs of #61461 (tests/test_ci_light_jobs_pool_mirror_checkout.py):
an unfiltered depth-2 fetch into a .git that borrows /var/lib/cmux-git, reusing the previous job's .git when this
step made it, so `git checkout` writes only what changed. Its sparse file is the step's three paths plus the
commit's own scripts/ci/path-route-sparse-checkout.txt, so the tree is the wide one from the start; the widen step
that follows finds a full clone, fetches nothing and sets the same patterns. Every other runner keeps
actions/checkout and its two retries; the routing, its inputs and its outputs are unchanged.
