# nightly.yml: job `published-build`, step "Name the run that published"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Anyone who may dispatch this workflow writes the input, and the tail checks out the record's build
commit with the Sparkle key. So the input only names the run: the API says what that run is, and the
record comes from its own artifact, which only its jobs can write.
