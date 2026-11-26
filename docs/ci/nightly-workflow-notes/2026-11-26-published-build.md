# nightly.yml `published-build`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 && (github.event_name`

A refused publication (the final gate, a superseded recheck, a refused feed write) is a green publish job that
moved no feed: run 45607031207's gate refused on a red App Store shelf, yet this job, the dispatch and the
"Finish a published nightly-next build" run all went green. So it runs only for a publication that went out,
and reads the feed back (below) before it says so.
Secret-free (python3 and the run's own token), so on Leo's ask (ask-c0123d25e8, "why so long that they didnt
publish either tho") it takes the nightly's reserved Linux label: on the nightly-only minis it queued 8-17 min
behind 25-min tail pollers before the GitHub release could start (runs 45572455172, 45575194160).

## 2

Above: `- name: Name the run that published`

Anyone who may dispatch this workflow writes the input, and the tail checks out the record's build
commit with the Sparkle key. So the input only names the run: the API says what that run is, and the
record comes from its own artifact, which only its jobs can write.

## 3

Above: `- name: Read the published build back from the live feed`

The job's own claim, read back: the build it says went out is on the live nightly-next feed (Leo's app reads
it), as its newest item or under a newer build that already published. Red here stops the dispatch and the tail.
