# nightly.yml: job `published-build`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A refused publication (the final gate, a superseded recheck, a refused feed write) is a green publish job that
moved no feed: run 45607031207's gate refused on a red App Store shelf, yet this job, the dispatch and the
"Finish a published nightly-next build" run all went green. So it runs only for a publication that went out,
and reads the feed back (below) before it says so.
Secret-free (python3 and the run's own token), so on Leo's ask (ask-c0123d25e8, "why so long that they didnt
publish either tho") it takes the nightly's reserved Linux label: on the nightly-only minis it queued 8-17 min
behind 25-min tail pollers before the GitHub release could start (runs 45572455172, 45575194160).
