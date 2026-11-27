# The fleet build's REF capture: timed from the job without an API call, bounded inside the job, never lost

Where: `cmux-scheme-compile`, steps `Capture the fleet build's REF` (`hybrid-ref-capture`) and `Upload the REF
capture manifest`; the time rules are constants in `scripts/cmux-next/hybrid_ref_capture.py` (`JOB_LIMIT_S`,
`LATEST_START_S`, `STEP_BUDGET_S`). Replaces the job-age part of note-407.

Run 45845663445 (2026-11-26) compiled green and lost its capture. The step's jobs read for the job's start got
"API rate limit exceeded for installation" (the decide step's artifact lookup had hit the same limit), the cmux-ci
client then updated itself inside the step, and the step hit its 8-minute limit while uploading: it had written no
manifest yet, so nothing was uploaded and the next run could not tell a capture had been tried.

Now:

- The job's start comes from the runner's per-job worker process (`ps`, Runner.Worker's elapsed time) and the
  decide step's `started` output, the earlier of the two; the GitHub jobs read runs only when neither is known, one
  try with a 15-second timeout. An unknown start still skips the capture.
- A capture starts only while the job is under 30 minutes old and stops itself 16 minutes later; the step's
  backstop is 18 minutes. 30 + 18 + the manifest upload's 2 leaves the 60-minute job 10 minutes, as before. The
  limit came from the one measured capture: it reached the step at job minute 21.5 (an 18-minute compile), packed
  in under 2 minutes, and was still uploading after 6.5 minutes. The same job's own artifact upload moved 236 MB
  in 80 s on that runner (about 3 MB/s), so 14 minutes of upload carries about 2.5 GB.
- Uploads run three at a time, each with the time left as its timeout, and with `CMUX_CI_NO_UPDATE=1`: a capture
  is no place for the client to update itself (the client checks for an update at most every 5 minutes and
  re-executes into the new one; build-fleet/client_install.py in cmuxterm-hq).
- The manifest is written before packing and after each stage, `"complete": false` until every part is in the
  store, so a capture that times out, fails an upload or runs out of time still leaves a manifest. The upload step
  runs whenever the capture step ran, from the manifest's fixed path, and names it
  `hybrid-ref-capture-incomplete-KEY` unless the capture finished: the next run's decide step sees it.
