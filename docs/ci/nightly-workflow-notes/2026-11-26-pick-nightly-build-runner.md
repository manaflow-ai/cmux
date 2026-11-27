# nightly.yml: job `pick-nightly-build-runner`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Beside resolve-nightly-cmux-tui-client, not after it: the pick reads only decide's outputs, and build-nightly-app
still needs both. One runner pickup off the path to the app build (nightly-30min; run 41941610932 waited 5.9 min
here after resolve). It keeps resolve's gate, so it runs only when resolve does.
