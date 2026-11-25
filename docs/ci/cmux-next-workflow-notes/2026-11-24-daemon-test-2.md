# 2026-11-24-daemon-test-2

Above `generated-files-base-red:` in `.github/workflows/cmux-next.yml`.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." While cmux-next generated files
is red on feat-cmux-next's base tier run (cmux-next-base-tier-kick.yml; pushes skip the job), a pull request's
Mac run of it is red too and gh-merge-green excuses that red as the base's, so it is skipped
(scripts/ci/base_red_skip.py: fails open, 10% of skips still run as the audit, label full-ci runs it,
vars.CI_SKIP_WHILE_BASE_RED == '0' turns it off). 2026-11-24: 0 of 37 PR runs green in 2 h, about 10k min a day.
