# Nightly builder routing and cache budget

nightly-next: pick-nightly-build-runner's dedicated builder, else an idle owned
label, else the moving Blacksmith label; never one label with no fallback. Main's
ci-cache-writer environment never follows NEXT onto that worker.
nightly-next: env artifacts holds CMUX_STORE_SIGNING_KEY (store packages, "Build the web bundles").
The cloud cache is scoped per branch and also drops main's own
entry (runs 35179030871 and 35182663752 restored nothing and were
cancelled at 45 minutes mid-compile), so the budget must fit a cold
build, not only a warm one.

Workflow size detectors: `tests/test_workflow_file_size.py` and
`tests/test_nightly_workflow_size.py`. These notes moved out of YAML without
changing the runner, environment, or timeout expressions.
