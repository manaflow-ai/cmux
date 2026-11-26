# 2026-11-25-daemon-reuse

Above `daemon-test: Fingerprint this job's inputs` and `daemon-test: Record this pass for the same inputs` in
`.github/workflows/cmux-next.yml`.

Leo, 2026-11-25: "linux... more motherfucking linux, better motherfucking caching".

The daemon suites took about 25 Mac minutes per run and never reused a pass. They now key like swift test
(scripts/ci/job_input_fingerprint.py `daemon-test`: the whole tree, the workflow blob, the Mac toolchain, the web
bundles' source key, the GUI flag, the Xcode app and the generated-files base) and look up a pass recorded under that
key before they take any build step (scripts/ci/job_reuse.py, `vars.CI_NEXT_JOB_REUSE == '1'`). A pull request's last
pass on its merge tree is the feat-cmux-next push's tree when nothing landed in between, so the push skips the suites.
The lookup uses the workflow token (artifact listing needs no secret here). A pass is recorded only when the run's
generated-files verdict, if it gave one, was fresh, so a hit reports `fresh`. A hit skips the base autofix exports
pack, as generated-files does.
