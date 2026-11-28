# 2026-11-28-pool-ws-per-sparse-list

In `.github/workflows/cmux-next.yml`, in the sparse checkout script that keeps one workspace per sparse list.

          [[ -d "$mirror" ]] || { echo "::error::no git mirror at $mirror on this pool VM"; exit 1; }
One reused workspace per sparse list (rnd rc-454d007c): jobs with different lists took turns with one .git on this
VM, so a job after a narrower one widened the tree first (median 6.4 s widening the guards' list to the fast gates',
1.8 s reusing the same list, 5.1 s fresh: bench run 46133992029, 4 runs each). Each list keeps its own workspace
