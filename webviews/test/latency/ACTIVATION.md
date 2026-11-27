# Stage and activate the Chromium performance gate

The workflow is staged with a manual trigger. Do not add its pull request trigger or require
its check while the trusted target branch lacks the validator, budget, or a numeric baseline.
The validator continues to reject a pending baseline. This stage does not satisfy the every-PR gate.

1. Push the complete integration head. From its clean worktree, submit one existing Linux fast-checks
   command, after coordinating the exact head and target base with the owner:

   ```sh
   CMUX_FAST_CHECKS_FALLBACK_AFTER=0 cmux-ci test --setup playwright --timeout 2400 -- \
     bash scripts/ci/web-perf-bootstrap.sh FULL_PUSHED_HEAD FULL_TARGET_BASE
   ```

   Disabling fallback keeps this measurement on Linux. Resume an inconclusive wait with the receipt
   printed by the helper; never redispatch. The command uses a separate exact-head worktree while
   retaining the snapshot HEAD expected by fast-checks. It builds production fixtures once and measures
   10 runs of each of the 16 trusted cases, including both 3,000-turn variants and real rail drag.

2. Download the run's `fast-checks-output` artifact
   (`gh run download RUN -R manaflow-ai/cmux -n fast-checks-output -D DIR`). It holds
   `web-perf-evidence.tar.gz` and its `.sha256`; verify the SHA256 (also printed in the log) before
   extraction. Run outside fast-checks, the script prints the tarball as base64 between
   `WEB_PERF_EVIDENCE_BASE64_START` and `WEB_PERF_EVIDENCE_BASE64_END` in the log instead. It contains raw Chromium timeline JSON, raw samples and adapter observations, source
   provenance, the actual baseline candidate, and the sorted numeric report. Timelines include action
   preparation and control work; target paint proxies and cadence are not Event Timing INP.
   CPU is renderer main-thread `ThreadTime`; OS wakeups remain null with an unsupported reason.

3. Independently review the capture, measured head, target base, browser version, raw traces and top
   ten p95 values. An over-budget run still retains its measured baseline and fails. Open a fixing PR
   for every top-ten case above 50 ms before granting an exception. Never substitute estimated numbers.
   Commit only the measured `baseline.json` as `test/latency/baseline.json`; do not commit raw artifacts.

4. Land trusted policy plus that reviewed numeric baseline on `feat-cmux-next`, then activate this
   gate in a separate PR with a trigger whose workflow file comes from the base, not the PR:
   `workflow_run` after the PR's CI (or `pull_request_target`), never plain `pull_request`. Under
   `pull_request` GitHub runs the PR's own copy of this workflow, so a PR could change what is measured
   and validated. The activated measurement job checks out the base, takes only the candidate's app
   source (`webviews/src`) and builds it with the base's lockfile, tooling and harness, so candidate code
   runs only inside the browser. Until then, the base-harness pin below guards against a harness that
   drifted in the PR, not against a hostile PR. That activation PR must retain the complete 16-case capture and obtain independent review.
   The measurement job measures the candidate's app with the target base's harness
   (`webviews/scripts/latency` and `webviews/test/latency` checked out from the base, recorded as
   `source.harness`), and validation requires that (`--require-base-harness`), so a candidate can't report
   numbers its own harness made up. A harness change therefore takes effect for the PRs after it lands.
   Validation runs on a separate fresh cloud runner that checks out only the exact target base.
   It downloads measurement artifacts as data, verifies every raw trace file's bytes, hash and timeline,
   and runs the base validator and policy with both expected head and expected base. Candidate code,
   installed tools, and temporary files from measurement never execute in the validation job.

The measured baseline head is historical provenance. Each future PR base is checked separately;
advancing the target branch does not silently relabel or invalidate those historical measurements.
The run installs/builds only the candidate head, never a second production tree for the base.
