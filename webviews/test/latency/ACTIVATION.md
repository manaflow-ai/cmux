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

2. Extract the base64 tarball between `WEB_PERF_EVIDENCE_BASE64_START` and
   `WEB_PERF_EVIDENCE_BASE64_END` in the retained run log. Verify the printed tarball SHA256 before
   extraction. It contains raw Chromium timeline JSON, raw samples and adapter observations, source
   provenance, the actual baseline candidate, and the sorted numeric report. Timelines include action
   preparation and control work; target paint proxies and cadence are not Event Timing INP.
   CPU is renderer main-thread `ThreadTime`; OS wakeups remain null with an unsupported reason.

3. Independently review the capture, measured head, target base, browser version, raw traces and top
   ten p95 values. An over-budget run still retains its measured baseline and fails. Open a fixing PR
   for every top-ten case above 50 ms before granting an exception. Never substitute estimated numbers.
   Commit only the measured `baseline.json` as `test/latency/baseline.json`; do not commit raw artifacts.

4. Land trusted policy plus that reviewed numeric baseline on `feat-cmux-next`, then activate this
   workflow in a separate PR by adding `pull_request: { branches: [feat-cmux-next] }` without a paths
   filter. That activation PR must retain the complete 16-case capture and obtain independent review.
   Validation runs on a separate fresh cloud runner that checks out only the exact target base.
   It downloads measurement artifacts as data, verifies every raw trace file's bytes, hash and timeline,
   and runs the base validator and policy with both expected head and expected base. Candidate code,
   installed tools, and temporary files from measurement never execute in the validation job.

The measured baseline head is historical provenance. Each future PR base is checked separately;
advancing the target branch does not silently relabel or invalidate those historical measurements.
The run installs/builds only the candidate head, never a second production tree for the base.
