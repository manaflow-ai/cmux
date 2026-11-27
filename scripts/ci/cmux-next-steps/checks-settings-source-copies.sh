#!/usr/bin/env bash
# cmux-next.yml checks: "Settings source copies".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
python3 -I scripts/cmux-next/gen-settings-sources.py --check
python3 -I scripts/cmux-next/tests/test_settings_export_keys.py
python3 -I scripts/cmux-next/tests/test_settings_section_type_budget.py
python3 -I scripts/cmux-next/tests/test_settings_swift_out.py
python3 -I scripts/cmux-next/tests/test_settings_agent_policy_files.py
bash scripts/cmux-next/tests/export-settings-linux.test.sh
