#!/usr/bin/env bash
# cmux-next.yml job `checks`, step "Start the slow checks in the background". Moved out of the workflow to keep it under
# GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py); its env: stays in the workflow.
# Why: note-27c
# Why: 2026-11-24-checks-3.md
POOL_TAIL_SECONDS=300
now="$(date +%s)"
# The cap counts from the job's start, and runner setup plus checkout took 339 s of it (job
# 139488442932); the event file's mtime fell back to now there, so the pool ran past the cap. The
# Runner.Worker process starts with the job: its age is the job's age.
job_start=""
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
  if [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = Runner.Worker ]; then
    age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ "$age" =~ ^[0-9]+$ ]] && job_start=$(( now - age ))
    break
  fi
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
done
[ -n "$job_start" ] || job_start="$(python3 -c 'import os, sys; print(int(os.path.getmtime(sys.argv[1])))' \
  "$GITHUB_EVENT_PATH" 2>/dev/null || date +%s)"
echo "checks pool: job started $(( now - job_start )) s ago"
# Why: 2026-11-24-checks-4.md
(( job_start <= now && now - job_start < JOB_TIMEOUT_MINUTES * 60 )) || job_start="$now"
deadline=$(( job_start + JOB_TIMEOUT_MINUTES * 60 - POOL_TAIL_SECONDS ))
# Why: 2026-11-24-checks-5.md
scripts/ci/run-checks-concurrently.sh --start "$RUNNER_TEMP/background-checks" --jobs "$(getconf _NPROCESSORS_ONLN)" \
  --deadline-at "$deadline" --affected "$AFFECTED_BASE" < scripts/ci/cmux-next-slow-checks.txt
