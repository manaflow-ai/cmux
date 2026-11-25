#!/usr/bin/env bash
# cmux-next.yml path_route: "Write the tree wait marker". Moved out of the workflow to keep cmux-next.yml under
# its size budget (tests/test_ci_workflow_file_size.py); the step's env: still sets every input, and the step runs
# it with `bash -e` as GitHub's default `bash -e {0}` ran the inline block.
set -euo pipefail
dir="$RUNNER_TEMP/cmux-next-tree-wait"
mkdir -p "$dir"
python3 - "$dir/marker.json" <<'PY'
import json, os, sys
env = os.environ
tiers = [tier for tier, on in (("daemon", env["DAEMON"]), ("scheme", env["SCHEME"])) if on == "true"]
marker = {"version": 1, "key": env["KEY"], "sha": env["SHA"], "status_sha": env["STATUS_SHA"],
          "tiers": tiers, "run_id": int(env["GITHUB_RUN_ID"])}
if env["DEV_DAILY"] == "true":
    marker.update(dev_daily=True, dev_daily_sha=env["DEV_DAILY_SHA"])
if env["EVENT_NAME"] == "pull_request":
    marker.update(origin="pull_request", pr=int(env["PR_NUMBER"]), head_ref=env["HEAD_REF"],
                  head_repo=env["HEAD_REPO"], base_ref=env["BASE_REF"])
else:
    # A dispatch on a working branch (#22303) is not a push: its same-tree run still
    # runs daemon-test, which a push's skips. The DEV daily stays a feat-cmux-next push.
    if env["EVENT_NAME"] == "workflow_dispatch" and env["DEV_DAILY"] != "true":
        marker.update(origin="dispatch", branch=env["BRANCH"],
                      ref_kind="tags" if env["REF_TYPE"] == "tag" else "heads")
        # The tip daemon suite tests this exact commit, like the DEV daily: its same-tree run
        # starts after the tip moves on (scripts/ci/cmux_next_tree_notify.py is_current).
        if env.get("TIP_DAEMON_SUITE") == "true" and env["BRANCH"] == "feat-cmux-next":
            marker.update(tip_suite="daemon")
        # The base tier likewise (cmux-next-base-tier-kick.yml): its same-tree run is the base
        # verdict for this commit and is named after it.
        elif env.get("BASE_TIER") == "true" and env["BRANCH"] == "feat-cmux-next":
            marker.update(tip_suite="base")
    else:
        marker.update(origin="push", branch=env["BRANCH"])
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(marker, stream)
print(json.dumps(marker))
PY
echo "path=$dir/marker.json" >> "$GITHUB_OUTPUT"
