# cmux-next.yml preamble: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `preamble` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `- release-notes/next/highlights/**`

The feature tips' source (webviews/scripts/pages/gen-feature-tips.mjs).

## 2

Stood above: `- release-notes/next/highlights/**`

The feature tips' source (webviews/scripts/pages/gen-feature-tips.mjs).

## 3

Stood above: `- web/data/model-catalog/**`

Files outside webviews/ that webviews sources import (web-bundle-key.py --inputs;
tests/test_web_bundle_key_inputs.sh keeps this list complete).
