# 2026-11-27-published-build-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 && (github.event_name == 'push' || github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' && inputs.nightly_next_loop_retry == '') && 'cmux-gcp-nightly-x64' || 'cmux-linux' }}` (job `published-build`) in `.github/workflows/nightly.yml`.

A refused publication (the final gate, a superseded recheck, a refused feed write) is a green publish job that
moved no feed: run 45607031207's gate refused on a red App Store shelf, yet this job, the dispatch and the
"Finish a published nightly-next build" run all went green. So it runs only for a publication that went out,
and reads the feed back (below) before it says so.
Secret-free (python3 and the run's own token), so on Leo's ask (ask-c0123d25e8, "why so long that they didnt
publish either tho") it takes the nightly's reserved Linux label: on the nightly-only minis it queued 8-17 min
behind 25-min tail pollers before the GitHub release could start (runs 45572455172, 45575194160).
