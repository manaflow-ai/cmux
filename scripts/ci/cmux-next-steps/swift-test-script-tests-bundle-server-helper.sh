#!/usr/bin/env bash
# cmux-next.yml swift-test: "Script tests (bundle-server-helper)".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
bash scripts/cmux-next/tests/bundle-server-helper.test.sh
bash scripts/cmux-next/tests/bundle-cmux-tui-launch-preread.test.sh
bash scripts/cmux-next/tests/install-cmux-tui-client-require-companions.test.sh
bash scripts/cmux-next/tests/stamp-launchd-plists.test.sh
bash scripts/cmux-next/tests/sign-cmux-bundle-helpers.test.sh
bash tests/test_check_app_personalities.sh
