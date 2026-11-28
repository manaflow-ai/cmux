# nightly.yml: job `workflow_dispatch`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The retired cmux NEXT-identity feed (com.cmuxterm.app.nightly.cmux-next).
It gets no builds, only the handover item that sends a stray install to
cmux NIGHTLY (publish-nightly). The canary verdicts and pulled.json stay
in its folder, where the app reads them (UpdaterService.channelFolder).
