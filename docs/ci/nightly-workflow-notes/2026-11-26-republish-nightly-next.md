# nightly.yml `republish-nightly-next`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- name: Upload the republished build's Chromium runtime pack`

publish-nightly reads the pack by this run's name when the source build has one (its cef
output), whatever CMUX_NEXT_CEF_ON_DEMAND says now: the app's pin names that pack.

## 2

Above: `- name: Upload the republished build's language packs`

The same for the source build's language packs (its language_packs output), whatever
CMUX_NEXT_LANGUAGE_PACKS says now: the app's pin names them.
